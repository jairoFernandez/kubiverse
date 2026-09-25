package main

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// PodDetail is everything the game draws inside a pod (the fish tank):
// containers and init containers with their state, resources, probes,
// ports and mounts, the pod's volumes and its recent events. Secret and
// ConfigMap contents are never included, only their names.
type PodDetail struct {
	NS         string          `json:"ns"`
	Name       string          `json:"name"`
	Node       string          `json:"node"`
	IP         string          `json:"ip"`
	Phase      string          `json:"phase"`
	QoS        string          `json:"qos"`
	SA         string          `json:"service_account"`
	Age        int64           `json:"age"`
	Conditions []PodCondition  `json:"conditions"`
	Init       []ContainerInfo `json:"init"`
	Containers []ContainerInfo `json:"containers"`
	Volumes    []VolumeInfo    `json:"volumes"`
	Events     []EventInfo     `json:"events"`
	Metrics    bool            `json:"metrics"` // per-container usage available
}

type PodCondition struct {
	Type   string `json:"type"`
	Status bool   `json:"status"`
	Reason string `json:"reason,omitempty"`
}

type ContainerInfo struct {
	Name       string      `json:"name"`
	Image      string      `json:"image"`
	State      string      `json:"state"` // running | waiting | terminated
	Reason     string      `json:"reason,omitempty"`
	Message    string      `json:"message,omitempty"`
	ExitCode   int32       `json:"exit_code"`
	Ready      bool        `json:"ready"`
	Started    int64       `json:"started"` // unix seconds, running since
	Restarts   int32       `json:"restarts"`
	LastReason string      `json:"last_reason,omitempty"` // why the previous run ended
	LastExit   int32       `json:"last_exit"`
	Sidecar    bool        `json:"sidecar"` // init container with restartPolicy Always
	CPUReq     int64       `json:"cpu_req_m"`
	CPULim     int64       `json:"cpu_lim_m"`
	MemReq     int64       `json:"mem_req"`
	MemLim     int64       `json:"mem_lim"`
	CPUUse     int64       `json:"cpu_use_m"`
	MemUse     int64       `json:"mem_use"`
	Ports      []PortInfo  `json:"ports"`
	Probes     []ProbeInfo `json:"probes"`
	Mounts     []MountInfo `json:"mounts"`
	EnvFrom    []string    `json:"env_from"` // "configmap/x", "secret/y"
	Env        int         `json:"env"`      // number of env vars (values not sent)
}

type PortInfo struct {
	Name     string `json:"name"`
	Port     int32  `json:"port"`
	Protocol string `json:"protocol"`
}

type ProbeInfo struct {
	Kind    string `json:"kind"`    // liveness | readiness | startup
	Handler string `json:"handler"` // "http GET :8080/healthz", "tcp :5432", "exec", "grpc :9000"
	Period  int32  `json:"period"`
	Failure int32  `json:"failure"`
	Delay   int32  `json:"delay"`
}

type MountInfo struct {
	Volume   string `json:"volume"`
	Path     string `json:"path"`
	ReadOnly bool   `json:"read_only"`
}

type VolumeInfo struct {
	Name   string `json:"name"`
	Type   string `json:"type"`   // configMap | secret | pvc | emptyDir | projected | hostPath | other
	Source string `json:"source"` // what it points to (name, claim, path)
}

type EventInfo struct {
	Type    string `json:"type"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
	Count   int32  `json:"count"`
	Age     int64  `json:"age"`
}

func (b *Bridge) handlePod(w http.ResponseWriter, r *http.Request) {
	ns, name := r.URL.Query().Get("ns"), r.URL.Query().Get("name")
	p, err := b.podLister.Pods(ns).Get(name)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": fmt.Sprintf("pod %s/%s not found", ns, name)})
		return
	}
	b.mu.Lock()
	usage := b.ctrUsage[ns+"/"+name]
	b.mu.Unlock()
	d := podDetail(p, usage)
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if evs, err := b.cs.CoreV1().Events(ns).List(ctx, metav1.ListOptions{FieldSelector: "involvedObject.name=" + name, Limit: 50}); err == nil {
		items := evs.Items
		sort.Slice(items, func(i, j int) bool { return eventTime(items[i]).After(eventTime(items[j])) })
		for i, e := range items {
			if i == 6 {
				break
			}
			d.Events = append(d.Events, EventInfo{Type: e.Type, Reason: e.Reason, Message: clip(e.Message, 240),
				Count: e.Count, Age: int64(time.Since(eventTime(e)).Seconds())})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "pod": d})
}

func podDetail(p *corev1.Pod, usage map[string]Usage) PodDetail {
	d := PodDetail{NS: p.Namespace, Name: p.Name, Node: p.Spec.NodeName, IP: p.Status.PodIP, Phase: string(p.Status.Phase),
		QoS: string(p.Status.QOSClass), SA: p.Spec.ServiceAccountName, Age: int64(time.Since(p.CreationTimestamp.Time).Seconds()),
		Metrics: usage != nil, Conditions: []PodCondition{}, Init: []ContainerInfo{}, Containers: []ContainerInfo{},
		Volumes: []VolumeInfo{}, Events: []EventInfo{}}
	for _, c := range p.Status.Conditions {
		d.Conditions = append(d.Conditions, PodCondition{Type: string(c.Type), Status: c.Status == corev1.ConditionTrue, Reason: c.Reason})
	}
	status := func(list []corev1.ContainerStatus, name string) *corev1.ContainerStatus {
		for i := range list {
			if list[i].Name == name {
				return &list[i]
			}
		}
		return nil
	}
	for _, c := range p.Spec.InitContainers {
		ci := containerInfo(c, status(p.Status.InitContainerStatuses, c.Name), usage)
		ci.Sidecar = c.RestartPolicy != nil && *c.RestartPolicy == corev1.ContainerRestartPolicyAlways
		d.Init = append(d.Init, ci)
	}
	for _, c := range p.Spec.Containers {
		d.Containers = append(d.Containers, containerInfo(c, status(p.Status.ContainerStatuses, c.Name), usage))
	}
	for _, v := range p.Spec.Volumes {
		vi := VolumeInfo{Name: v.Name, Type: "other"}
		switch {
		case v.ConfigMap != nil:
			vi.Type, vi.Source = "configMap", v.ConfigMap.Name
		case v.Secret != nil:
			vi.Type, vi.Source = "secret", v.Secret.SecretName
		case v.PersistentVolumeClaim != nil:
			vi.Type, vi.Source = "pvc", v.PersistentVolumeClaim.ClaimName
		case v.EmptyDir != nil:
			vi.Type = "emptyDir"
		case v.Projected != nil:
			vi.Type = "projected"
		case v.HostPath != nil:
			vi.Type, vi.Source = "hostPath", v.HostPath.Path
		}
		d.Volumes = append(d.Volumes, vi)
	}
	return d
}

func containerInfo(c corev1.Container, st *corev1.ContainerStatus, usage map[string]Usage) ContainerInfo {
	ci := ContainerInfo{Name: c.Name, Image: c.Image, State: "waiting", Ports: []PortInfo{}, Probes: []ProbeInfo{},
		Mounts: []MountInfo{}, EnvFrom: []string{}, Env: len(c.Env)}
	ci.CPUReq = c.Resources.Requests.Cpu().MilliValue()
	ci.CPULim = c.Resources.Limits.Cpu().MilliValue()
	ci.MemReq = c.Resources.Requests.Memory().Value()
	ci.MemLim = c.Resources.Limits.Memory().Value()
	if u, ok := usage[c.Name]; ok {
		ci.CPUUse, ci.MemUse = u.CPUm, u.MemBytes
	}
	for _, p := range c.Ports {
		ci.Ports = append(ci.Ports, PortInfo{Name: p.Name, Port: p.ContainerPort, Protocol: string(p.Protocol)})
	}
	for _, pr := range []struct {
		kind string
		p    *corev1.Probe
	}{{"liveness", c.LivenessProbe}, {"readiness", c.ReadinessProbe}, {"startup", c.StartupProbe}} {
		if pr.p == nil {
			continue
		}
		pi := ProbeInfo{Kind: pr.kind, Handler: "exec", Period: pr.p.PeriodSeconds, Failure: pr.p.FailureThreshold, Delay: pr.p.InitialDelaySeconds}
		switch {
		case pr.p.HTTPGet != nil:
			pi.Handler = fmt.Sprintf("http GET :%s%s", pr.p.HTTPGet.Port.String(), pr.p.HTTPGet.Path)
		case pr.p.TCPSocket != nil:
			pi.Handler = "tcp :" + pr.p.TCPSocket.Port.String()
		case pr.p.GRPC != nil:
			pi.Handler = fmt.Sprintf("grpc :%d", pr.p.GRPC.Port)
		}
		ci.Probes = append(ci.Probes, pi)
	}
	for _, m := range c.VolumeMounts {
		ci.Mounts = append(ci.Mounts, MountInfo{Volume: m.Name, Path: m.MountPath, ReadOnly: m.ReadOnly})
	}
	for _, e := range c.EnvFrom {
		if e.ConfigMapRef != nil {
			ci.EnvFrom = append(ci.EnvFrom, "configmap/"+e.ConfigMapRef.Name)
		}
		if e.SecretRef != nil {
			ci.EnvFrom = append(ci.EnvFrom, "secret/"+e.SecretRef.Name)
		}
	}
	if st == nil {
		return ci
	}
	ci.Ready, ci.Restarts = st.Ready, st.RestartCount
	switch {
	case st.State.Running != nil:
		ci.State, ci.Started = "running", st.State.Running.StartedAt.Unix()
	case st.State.Terminated != nil:
		ci.State, ci.Reason, ci.Message, ci.ExitCode = "terminated", st.State.Terminated.Reason, clip(st.State.Terminated.Message, 200), st.State.Terminated.ExitCode
	case st.State.Waiting != nil:
		ci.State, ci.Reason, ci.Message = "waiting", st.State.Waiting.Reason, clip(st.State.Waiting.Message, 200)
	}
	if t := st.LastTerminationState.Terminated; t != nil {
		ci.LastReason, ci.LastExit = t.Reason, t.ExitCode
	}
	return ci
}

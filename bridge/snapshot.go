package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/labels"
)

// Snapshot is the full cluster view pushed to the game. It is intentionally
// flat and game-friendly: the game never needs to understand raw k8s objects.
type Snapshot struct {
	Context    string      `json:"context"`
	Server     string      `json:"server"`
	ReadOnly   bool        `json:"readonly"`
	Time       int64       `json:"time"`
	Nodes      []Node      `json:"nodes"`
	Namespaces []Namespace `json:"namespaces"`
	Pods       []Pod       `json:"pods"`
	Workloads  []Workload  `json:"workloads"`
	Services   []Service   `json:"services"`
	Ingresses  []Ingress   `json:"ingresses"`
	Metrics    Metrics     `json:"metrics"`
	Alerts     []Alert     `json:"alerts"` // firing (Alertmanager / Prometheus rules)
	// Beyond workloads (each empty when it can't be listed).
	Volumes        []Volume       `json:"volumes"` // PersistentVolumeClaims
	StorageClasses []StorageClass `json:"storage_classes"`
	Apps           []ArgoApp      `json:"apps"`  // Argo CD Applications
	Certs          []Cert         `json:"certs"` // cert-manager Certificates
	PVs            []PV           `json:"pvs"`
	Configs        []ConfigRef    `json:"configs"` // Secrets and ConfigMaps (never their values)
}

type Node struct {
	Name          string   `json:"name"`
	Ready         bool     `json:"ready"`
	Unschedulable bool     `json:"unschedulable"`
	Roles         []string `json:"roles"`
	CPU           string   `json:"cpu"`
	Memory        string   `json:"memory"`
	PodCapacity   int64    `json:"pod_capacity"`
	Kubelet       string   `json:"kubelet"`
	OS            string   `json:"os"`
	Arch          string   `json:"arch"`
	Age           int64    `json:"age"`
	CPUm          int64    `json:"cpu_m"`      // allocatable millicores
	MemBytes      int64    `json:"mem_bytes"`  // allocatable memory
	Taints        []string `json:"taints"`     // "key=value:Effect"
	Conditions    []string `json:"conditions"` // abnormal ones: MemoryPressure, DiskPressure...
}

type Namespace struct {
	Name    string      `json:"name"`
	Phase   string      `json:"phase"`
	NetPols []NetPol    `json:"netpols,omitempty"`
	Quota   []QuotaItem `json:"quota,omitempty"`
	Limits  []string    `json:"limits,omitempty"` // LimitRanges in words
}

type Pod struct {
	Namespace  string   `json:"ns"`
	Name       string   `json:"name"`
	Node       string   `json:"node"`
	Phase      string   `json:"phase"`
	Status     string   `json:"status"`
	Ready      int      `json:"ready"`
	Total      int      `json:"total"`
	Restarts   int32    `json:"restarts"`
	OwnerKind  string   `json:"owner_kind"`
	OwnerName  string   `json:"owner_name"`
	Containers []string `json:"containers"`
	Images     []string `json:"images"`
	IP         string   `json:"ip"`
	Age        int64    `json:"age"`
	Deleting   bool     `json:"deleting"`
	CPUReqm    int64    `json:"cpu_req_m"`
	MemReq     int64    `json:"mem_req"`
	Message    string   `json:"message"`           // why it is not running (scheduler / container)
	NetPols    []string `json:"netpols,omitempty"` // NetworkPolicies that select it
}

type Workload struct {
	Kind      string `json:"kind"`
	Namespace string `json:"ns"`
	Name      string `json:"name"`
	Desired   int32  `json:"desired"`
	Ready     int32  `json:"ready"`
	Updated   int32  `json:"updated"`
	Available int32  `json:"available"`
	Image     string `json:"image"`
	// Who else has a say: a GitOps tool, an autoscaler, a disruption budget.
	GitOps   *GitOps `json:"gitops,omitempty"`
	HPA      *HPARef `json:"hpa,omitempty"`
	PDB      *PDBRef `json:"pdb,omitempty"`
	Paused   bool    `json:"paused,omitempty"`   // Deployment rollout paused
	Revision int64   `json:"revision,omitempty"` // Deployment rollout revision
}

type Service struct {
	Namespace string            `json:"ns"`
	Name      string            `json:"name"`
	Type      string            `json:"type"`
	ClusterIP string            `json:"cluster_ip"`
	Ports     []string          `json:"ports"`
	Selector  map[string]string `json:"selector"`
	Pods      []string          `json:"pods"`       // matched pod names (same namespace)
	Ready     int               `json:"ready"`      // matched pods that are ready (endpoints)
	External  []string          `json:"external"`   // LoadBalancer IPs/hostnames, externalIPs
	NodePorts []int32           `json:"node_ports"` // ports opened on every node
}

// Ingress: how outside traffic (domains, paths) reaches Services.
type Ingress struct {
	Namespace string        `json:"ns"`
	Name      string        `json:"name"`
	Class     string        `json:"class"`
	Rules     []IngressRule `json:"rules"`
	TLS       []string      `json:"tls"`     // hosts served over HTTPS
	Address   []string      `json:"address"` // where the ingress controller listens
}

type IngressRule struct {
	Host    string `json:"host"` // "" = any host
	Path    string `json:"path"`
	Service string `json:"service"`
	Port    string `json:"port"`
}

func (b *Bridge) buildSnapshot() (*Snapshot, error) {
	now := time.Now()
	s := &Snapshot{
		Context:  b.contextName,
		Server:   b.server,
		ReadOnly: b.readOnly,
		Time:     now.Unix(),
	}
	b.mu.Lock()
	s.Metrics = b.metrics
	b.mu.Unlock()
	s.Alerts = b.currentAlerts()
	if s.Alerts == nil {
		s.Alerts = []Alert{}
	}

	nodes, err := b.nodeLister.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	for _, n := range nodes {
		s.Nodes = append(s.Nodes, convertNode(n, now))
	}
	sort.Slice(s.Nodes, func(i, j int) bool { return s.Nodes[i].Name < s.Nodes[j].Name })

	nss, err := b.nsLister.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	for _, ns := range nss {
		s.Namespaces = append(s.Namespaces, Namespace{Name: ns.Name, Phase: string(ns.Status.Phase)})
	}
	sort.Slice(s.Namespaces, func(i, j int) bool { return s.Namespaces[i].Name < s.Namespaces[j].Name })

	// ReplicaSet -> Deployment owner resolution.
	rsOwner := map[string]string{}
	rss, _ := b.rsLister.List(labels.Everything())
	for _, rs := range rss {
		for _, o := range rs.OwnerReferences {
			if o.Kind == "Deployment" {
				rsOwner[rs.Namespace+"/"+rs.Name] = o.Name
			}
		}
	}

	pods, err := b.podLister.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	for _, p := range pods {
		s.Pods = append(s.Pods, convertPod(p, rsOwner, now))
	}
	sort.Slice(s.Pods, func(i, j int) bool {
		if s.Pods[i].Namespace != s.Pods[j].Namespace {
			return s.Pods[i].Namespace < s.Pods[j].Namespace
		}
		return s.Pods[i].Name < s.Pods[j].Name
	})

	deps, _ := b.depLister.List(labels.Everything())
	for _, d := range deps {
		desired := int32(1)
		if d.Spec.Replicas != nil {
			desired = *d.Spec.Replicas
		}
		s.Workloads = append(s.Workloads, Workload{
			Kind: "Deployment", Namespace: d.Namespace, Name: d.Name,
			Desired: desired, Ready: d.Status.ReadyReplicas, Updated: d.Status.UpdatedReplicas,
			Available: d.Status.AvailableReplicas, Image: firstImage(d.Spec.Template.Spec),
			GitOps: gitOpsOf(d.ObjectMeta), HPA: b.hpaFor("Deployment", d.Namespace, d.Name),
			PDB: b.pdbFor(d.Namespace, d.Spec.Template.Labels), Paused: d.Spec.Paused, Revision: revisionOf(d.ObjectMeta),
		})
	}
	sts, _ := b.stsLister.List(labels.Everything())
	for _, d := range sts {
		desired := int32(1)
		if d.Spec.Replicas != nil {
			desired = *d.Spec.Replicas
		}
		s.Workloads = append(s.Workloads, Workload{
			Kind: "StatefulSet", Namespace: d.Namespace, Name: d.Name,
			Desired: desired, Ready: d.Status.ReadyReplicas, Updated: d.Status.UpdatedReplicas,
			Available: d.Status.AvailableReplicas, Image: firstImage(d.Spec.Template.Spec),
			GitOps: gitOpsOf(d.ObjectMeta), HPA: b.hpaFor("StatefulSet", d.Namespace, d.Name),
			PDB: b.pdbFor(d.Namespace, d.Spec.Template.Labels),
		})
	}
	dss, _ := b.dsLister.List(labels.Everything())
	for _, d := range dss {
		s.Workloads = append(s.Workloads, Workload{
			Kind: "DaemonSet", Namespace: d.Namespace, Name: d.Name,
			Desired: d.Status.DesiredNumberScheduled, Ready: d.Status.NumberReady,
			Updated: d.Status.UpdatedNumberScheduled, Available: d.Status.NumberAvailable,
			Image: firstImage(d.Spec.Template.Spec), GitOps: gitOpsOf(d.ObjectMeta),
		})
	}
	sort.Slice(s.Workloads, func(i, j int) bool {
		a, c := s.Workloads[i], s.Workloads[j]
		return a.Namespace+"/"+a.Kind+"/"+a.Name < c.Namespace+"/"+c.Kind+"/"+c.Name
	})

	svcs, _ := b.svcLister.List(labels.Everything())
	for _, sv := range svcs {
		out := Service{
			Namespace: sv.Namespace, Name: sv.Name, Type: string(sv.Spec.Type),
			ClusterIP: sv.Spec.ClusterIP, Selector: sv.Spec.Selector, Pods: []string{},
		}
		for _, p := range sv.Spec.Ports {
			out.Ports = append(out.Ports, fmt.Sprintf("%d/%s", p.Port, p.Protocol))
			if p.NodePort != 0 {
				out.NodePorts = append(out.NodePorts, p.NodePort)
			}
		}
		for _, ing := range sv.Status.LoadBalancer.Ingress {
			if ing.IP != "" {
				out.External = append(out.External, ing.IP)
			} else if ing.Hostname != "" {
				out.External = append(out.External, ing.Hostname)
			}
		}
		out.External = append(out.External, sv.Spec.ExternalIPs...)
		if len(sv.Spec.Selector) > 0 {
			sel := labels.SelectorFromSet(sv.Spec.Selector)
			for _, p := range pods {
				if p.Namespace == sv.Namespace && sel.Matches(labels.Set(p.Labels)) {
					out.Pods = append(out.Pods, p.Name)
					if podReady(p) {
						out.Ready++
					}
				}
			}
			sort.Strings(out.Pods)
		}
		s.Services = append(s.Services, out)
	}
	sort.Slice(s.Services, func(i, j int) bool {
		return s.Services[i].Namespace+"/"+s.Services[i].Name < s.Services[j].Namespace+"/"+s.Services[j].Name
	})
	s.Ingresses = []Ingress{}
	if b.ingLister != nil {
		ings, _ := b.ingLister.List(labels.Everything())
		for _, ing := range ings {
			out := Ingress{Namespace: ing.Namespace, Name: ing.Name, Rules: []IngressRule{}}
			if ing.Spec.IngressClassName != nil {
				out.Class = *ing.Spec.IngressClassName
			}
			backend := func(svc *networkingv1.IngressServiceBackend) (string, string) {
				if svc == nil {
					return "", ""
				}
				if svc.Port.Name != "" {
					return svc.Name, svc.Port.Name
				}
				return svc.Name, fmt.Sprint(svc.Port.Number)
			}
			if db := ing.Spec.DefaultBackend; db != nil {
				n, port := backend(db.Service)
				out.Rules = append(out.Rules, IngressRule{Host: "", Path: "/*", Service: n, Port: port})
			}
			for _, r := range ing.Spec.Rules {
				if r.HTTP == nil {
					continue
				}
				for _, p := range r.HTTP.Paths {
					n, port := backend(p.Backend.Service)
					path := p.Path
					if path == "" {
						path = "/"
					}
					out.Rules = append(out.Rules, IngressRule{Host: r.Host, Path: path, Service: n, Port: port})
				}
			}
			for _, t := range ing.Spec.TLS {
				out.TLS = append(out.TLS, t.Hosts...)
			}
			for _, a := range ing.Status.LoadBalancer.Ingress {
				if a.IP != "" {
					out.Address = append(out.Address, a.IP)
				} else if a.Hostname != "" {
					out.Address = append(out.Address, a.Hostname)
				}
			}
			s.Ingresses = append(s.Ingresses, out)
		}
		sort.Slice(s.Ingresses, func(i, j int) bool {
			return s.Ingresses[i].Namespace+"/"+s.Ingresses[i].Name < s.Ingresses[j].Namespace+"/"+s.Ingresses[j].Name
		})
	}
	b.fillResources(s, pods, now)
	b.fillStorageAndConfig(s, pods, now)
	return s, nil
}

// podReady: running with every container ready (it would get traffic).
func podReady(p *corev1.Pod) bool {
	if p.DeletionTimestamp != nil || p.Status.Phase != corev1.PodRunning {
		return false
	}
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

func firstImage(spec corev1.PodSpec) string {
	if len(spec.Containers) > 0 {
		return spec.Containers[0].Image
	}
	return ""
}

func convertNode(n *corev1.Node, now time.Time) Node {
	out := Node{
		Name:          n.Name,
		Unschedulable: n.Spec.Unschedulable,
		CPU:           n.Status.Capacity.Cpu().String(),
		Memory:        n.Status.Capacity.Memory().String(),
		PodCapacity:   n.Status.Capacity.Pods().Value(),
		Kubelet:       n.Status.NodeInfo.KubeletVersion,
		OS:            n.Status.NodeInfo.OperatingSystem,
		Arch:          n.Status.NodeInfo.Architecture,
		Age:           int64(now.Sub(n.CreationTimestamp.Time).Seconds()),
		Roles:         []string{},
		CPUm:          n.Status.Allocatable.Cpu().MilliValue(),
		MemBytes:      n.Status.Allocatable.Memory().Value(),
	}
	out.Taints, out.Conditions = []string{}, []string{}
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			out.Ready = c.Status == corev1.ConditionTrue
		} else if c.Status == corev1.ConditionTrue {
			out.Conditions = append(out.Conditions, string(c.Type))
		}
	}
	for _, t := range n.Spec.Taints {
		s := t.Key
		if t.Value != "" {
			s += "=" + t.Value
		}
		out.Taints = append(out.Taints, s+":"+string(t.Effect))
	}
	for k := range n.Labels {
		if r, ok := strings.CutPrefix(k, "node-role.kubernetes.io/"); ok && r != "" {
			out.Roles = append(out.Roles, r)
		}
	}
	sort.Strings(out.Roles)
	return out
}

func convertPod(p *corev1.Pod, rsOwner map[string]string, now time.Time) Pod {
	out := Pod{
		Namespace: p.Namespace,
		Name:      p.Name,
		Node:      p.Spec.NodeName,
		Phase:     string(p.Status.Phase),
		IP:        p.Status.PodIP,
		Total:     len(p.Spec.Containers),
		Age:       int64(now.Sub(p.CreationTimestamp.Time).Seconds()),
		Deleting:  p.DeletionTimestamp != nil,
	}
	for _, c := range p.Spec.Containers {
		out.Containers = append(out.Containers, c.Name)
		out.Images = append(out.Images, c.Image)
		out.CPUReqm += c.Resources.Requests.Cpu().MilliValue()
		out.MemReq += c.Resources.Requests.Memory().Value()
	}
	for _, o := range p.OwnerReferences {
		if o.Controller != nil && *o.Controller {
			out.OwnerKind, out.OwnerName = o.Kind, o.Name
			if o.Kind == "ReplicaSet" {
				if d, ok := rsOwner[p.Namespace+"/"+o.Name]; ok {
					out.OwnerKind, out.OwnerName = "Deployment", d
				}
			}
		}
	}
	out.Status = podStatus(p)
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodScheduled && c.Status == corev1.ConditionFalse && c.Message != "" {
			out.Message = c.Message
		}
	}
	if out.Message == "" {
		for _, cs := range p.Status.ContainerStatuses {
			if cs.State.Waiting != nil && cs.State.Waiting.Message != "" {
				out.Message = cs.State.Waiting.Message
			} else if cs.State.Terminated != nil && cs.State.Terminated.Message != "" {
				out.Message = cs.State.Terminated.Message
			}
		}
	}
	for _, cs := range p.Status.ContainerStatuses {
		if cs.Ready {
			out.Ready++
		}
		out.Restarts += cs.RestartCount
	}
	return out
}

// podStatus mirrors the STATUS column of `kubectl get pods`.
func podStatus(p *corev1.Pod) string {
	if p.DeletionTimestamp != nil {
		return "Terminating"
	}
	reason := string(p.Status.Phase)
	if p.Status.Reason != "" {
		reason = p.Status.Reason
	}
	for _, cs := range p.Status.InitContainerStatuses {
		if cs.State.Waiting != nil && cs.State.Waiting.Reason != "" && cs.State.Waiting.Reason != "PodInitializing" {
			return "Init:" + cs.State.Waiting.Reason
		}
		if cs.State.Terminated != nil && cs.State.Terminated.ExitCode != 0 {
			return "Init:Error"
		}
	}
	for _, cs := range p.Status.ContainerStatuses {
		if cs.State.Waiting != nil && cs.State.Waiting.Reason != "" {
			reason = cs.State.Waiting.Reason
		} else if cs.State.Terminated != nil && cs.State.Terminated.Reason != "" {
			reason = cs.State.Terminated.Reason
		}
	}
	return reason
}

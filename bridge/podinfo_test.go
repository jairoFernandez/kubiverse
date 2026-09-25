package main

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestPodDetail(t *testing.T) {
	always := corev1.ContainerRestartPolicyAlways
	p := &corev1.Pod{
		Spec: corev1.PodSpec{
			InitContainers: []corev1.Container{{Name: "migrate"}, {Name: "proxy", RestartPolicy: &always}},
			Containers: []corev1.Container{{
				Name: "app", Image: "shop:1",
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m")},
					Limits:   corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("256Mi")},
				},
				Ports:          []corev1.ContainerPort{{Name: "http", ContainerPort: 8080, Protocol: "TCP"}},
				ReadinessProbe: &corev1.Probe{ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/ready", Port: intstr.FromInt32(8080)}}},
				VolumeMounts:   []corev1.VolumeMount{{Name: "cfg", MountPath: "/etc/app", ReadOnly: true}},
				EnvFrom:        []corev1.EnvFromSource{{SecretRef: &corev1.SecretEnvSource{LocalObjectReference: corev1.LocalObjectReference{Name: "db"}}}},
			}},
			Volumes: []corev1.Volume{{Name: "cfg", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "app-config"}}}}},
		},
		Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{{
			Name: "app", Ready: false, RestartCount: 3,
			State:                corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}},
			LastTerminationState: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{Reason: "OOMKilled", ExitCode: 137}},
		}}},
	}
	d := podDetail(p, map[string]Usage{"app": {CPUm: 42, MemBytes: 1 << 20}})
	if len(d.Init) != 2 || d.Init[0].Sidecar || !d.Init[1].Sidecar {
		t.Fatalf("init containers / sidecar: %+v", d.Init)
	}
	c := d.Containers[0]
	if c.State != "waiting" || c.Reason != "CrashLoopBackOff" || c.LastReason != "OOMKilled" || c.LastExit != 137 || c.Restarts != 3 {
		t.Fatalf("state: %+v", c)
	}
	if c.CPUReq != 100 || c.MemLim != 256<<20 || c.CPUUse != 42 || !d.Metrics {
		t.Fatalf("resources: %+v", c)
	}
	if len(c.Probes) != 1 || c.Probes[0].Handler != "http GET :8080/ready" || c.Mounts[0].Path != "/etc/app" || c.EnvFrom[0] != "secret/db" {
		t.Fatalf("probes/mounts/envFrom: %+v", c)
	}
	if d.Volumes[0].Type != "configMap" || d.Volumes[0].Source != "app-config" {
		t.Fatalf("volumes: %+v", d.Volumes)
	}
}

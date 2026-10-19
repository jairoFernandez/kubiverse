package main

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func startupPod(born time.Time) *corev1.Pod {
	at := func(s float64) metav1.Time { return metav1.NewTime(born.Add(time.Duration(s * float64(time.Second)))) }
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "api-1", Namespace: "shop", CreationTimestamp: metav1.NewTime(born)},
		Spec: corev1.PodSpec{Containers: []corev1.Container{
			{Name: "app", ReadinessProbe: &corev1.Probe{InitialDelaySeconds: 30, PeriodSeconds: 10},
				Resources: corev1.ResourceRequirements{Limits: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("500m")}}},
			{Name: "proxy", StartupProbe: &corev1.Probe{PeriodSeconds: 1},
				Resources: corev1.ResourceRequirements{Limits: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("200m")}}},
		}},
		Status: corev1.PodStatus{
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: at(1)},
				{Type: corev1.PodInitialized, Status: corev1.ConditionTrue, LastTransitionTime: at(3)},
				{Type: corev1.ContainersReady, Status: corev1.ConditionTrue, LastTransitionTime: at(45)},
				{Type: corev1.PodReady, Status: corev1.ConditionTrue, LastTransitionTime: at(45)},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "app", State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: at(11)}}},
				{Name: "proxy", State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: at(12)}}},
			},
		},
	}
}

// Every phase is read from the pod's conditions, container states and the
// kubelet's Pulled events.
func TestStartupTimeline(t *testing.T) {
	born := time.Unix(1700000000, 0)
	events := []corev1.Event{
		{Reason: "Pulled", Message: `Successfully pulled image "registry.example/api:1.4" in 7.5s (7.6s including waiting). Image size: 300000000 bytes.`},
		{Reason: "Pulled", Message: `Container image "envoyproxy/envoy:v1.31" already present on machine`},
		{Reason: "Started", Message: "Started container app"},
	}
	st := startupTimeline(startupPod(born), events)
	if st.Scheduled != 1 || st.Initialized != 3 || st.Started != 12 || st.Ready != 45 {
		t.Errorf("times = sched %v init %v started %v ready %v, want 1/3/12/45", st.Scheduled, st.Initialized, st.Started, st.Ready)
	}
	if st.Pull != 7.5 || st.Pulled != 1 || st.Cached != 1 || st.PullBytes != 300000000 {
		t.Errorf("pull = %vs pulled %d cached %d bytes %d, want 7.5/1/1/300000000", st.Pull, st.Pulled, st.Cached, st.PullBytes)
	}
	if st.ReadyDelay != 30 || st.ReadyPeriod != 10 || !st.StartupProbe || st.CPULimitM != 200 || st.Restarted {
		t.Errorf("probes/limits = %+v", st)
	}
}

// A pod still starting: what hasn't happened yet is -1, and with no Pulled
// events (they expire after an hour) the pull time is unknown.
func TestStartupTimelinePending(t *testing.T) {
	born := time.Unix(1700000000, 0)
	p := startupPod(born)
	p.Status.Conditions = p.Status.Conditions[:1]
	p.Status.ContainerStatuses[1].State = corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "ContainerCreating"}}
	st := startupTimeline(p, nil)
	if st.Scheduled != 1 || st.Initialized != -1 || st.Ready != -1 {
		t.Errorf("times = %+v", st)
	}
	if st.Started != -1 {
		t.Errorf("started = %v: not every container runs yet, want -1", st.Started)
	}
	if st.Pull != -1 || st.Pulled != 0 {
		t.Errorf("pull = %v with no events, want -1", st.Pull)
	}
}

// After a restart the times are those of the last start: the game says so.
func TestStartupTimelineRestarted(t *testing.T) {
	p := startupPod(time.Unix(1700000000, 0))
	p.Status.ContainerStatuses[0].RestartCount = 3
	if !startupTimeline(p, nil).Restarted {
		t.Error("a container restarted: the timeline must say so")
	}
}

// Go duration formats the kubelet prints: ms, minutes, mixed.
func TestStartupPullFormats(t *testing.T) {
	p := startupPod(time.Unix(1700000000, 0))
	for msg, want := range map[string]float64{
		`Successfully pulled image "a" in 512ms (512ms including waiting)`:   0.512,
		`Successfully pulled image "b" in 1m2.5s (1m2.5s including waiting)`: 62.5,
		`Successfully pulled image "c" in 3s`:                                3,
	} {
		st := startupTimeline(p, []corev1.Event{{Reason: "Pulled", Message: msg}})
		if diff := st.Pull - want; diff > 1e-9 || diff < -1e-9 {
			t.Errorf("%q: pull %v, want %v", msg, st.Pull, want)
		}
	}
	// Only cached images: nothing was downloaded, the pull took 0.
	st := startupTimeline(p, []corev1.Event{{Reason: "Pulled", Message: `Container image "x" already present on machine`}})
	if st.Pull != 0 || st.Cached != 1 {
		t.Errorf("cached only: pull %v cached %d, want 0 and 1", st.Pull, st.Cached)
	}
}

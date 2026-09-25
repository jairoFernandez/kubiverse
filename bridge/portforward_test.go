package main

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestForwardValidation(t *testing.T) {
	b := &Bridge{}
	for _, req := range []forwardRequest{
		{Kind: "deployment", NS: "a", Name: "b", Port: 80},
		{Kind: "pod", NS: "a", Name: "b", Port: 0},
		{Kind: "service", NS: "a", Name: "b", Port: 70000},
		{Kind: "pod", NS: "a", Name: "b", Port: 80, Local: -1},
	} {
		if _, err := b.startForward(req); err == nil {
			t.Errorf("%+v: expected an error", req)
		}
	}
}

func TestTargetPort(t *testing.T) {
	p := &corev1.Pod{Spec: corev1.PodSpec{Containers: []corev1.Container{{Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: 8081}}}}}}
	cases := []struct {
		tp   intstr.IntOrString
		port int32
		want int
	}{
		{intstr.FromInt32(9000), 80, 9000},
		{intstr.FromString("http"), 80, 8081},
		{intstr.FromString("grpc"), 80, 0},
		{intstr.IntOrString{}, 80, 80},
	}
	for _, c := range cases {
		if got := targetPort(p, c.tp, c.port); got != c.want {
			t.Errorf("targetPort(%v, %d) = %d, want %d", c.tp, c.port, got, c.want)
		}
	}
}

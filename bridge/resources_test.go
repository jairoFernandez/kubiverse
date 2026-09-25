package main

import (
	"strings"
	"testing"

	authorizationv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestNetPolInWords(t *testing.T) {
	deny := summarizeNetPol(&networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: "default-deny"},
		Spec: networkingv1.NetworkPolicySpec{PolicyTypes: []networkingv1.PolicyType{"Ingress", "Egress"}}})
	if deny.Selects != "all pods" || !deny.DenyIn || !deny.DenyOut {
		t.Fatalf("%+v", deny)
	}
	port := intstr.FromInt32(5432)
	allow := summarizeNetPol(&networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: "db"},
		Spec: networkingv1.NetworkPolicySpec{PodSelector: metav1.LabelSelector{MatchLabels: map[string]string{"app": "db"}},
			Ingress: []networkingv1.NetworkPolicyIngressRule{{From: []networkingv1.NetworkPolicyPeer{{PodSelector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "ledger"}}}},
				Ports: []networkingv1.NetworkPolicyPort{{Port: &port}}}}}})
	if allow.DenyIn || allow.Selects != "app=db" || allow.Ingress[0] != "from pods app=ledger on 5432" {
		t.Fatalf("%+v", allow)
	}
	if !allow.selector.Matches(labels.Set{"app": "db"}) || allow.selector.Matches(labels.Set{"app": "web"}) {
		t.Fatal("selector")
	}
}

func TestCanIWildcards(t *testing.T) {
	rules := []authorizationv1.ResourceRule{
		{Verbs: []string{"get", "list", "watch"}, APIGroups: []string{""}, Resources: []string{"pods", "pods/log"}},
		{Verbs: []string{"*"}, APIGroups: []string{"apps"}, Resources: []string{"*"}},
		{Verbs: []string{"get"}, APIGroups: []string{""}, Resources: []string{"secrets"}, ResourceNames: []string{"one"}},
	}
	for _, c := range []struct {
		verb, group, res string
		want             bool
	}{{"list", "", "pods", true}, {"delete", "", "pods", false}, {"patch", "apps", "deployments", true}, {"get", "", "secrets", false}} {
		if allowed(rules, c.verb, c.group, c.res) != c.want {
			t.Errorf("%v", c)
		}
	}
}

func TestLimitsInWords(t *testing.T) {
	lr := &corev1.LimitRange{ObjectMeta: metav1.ObjectMeta{Name: "defaults"}, Spec: corev1.LimitRangeSpec{Limits: []corev1.LimitRangeItem{{
		Type:           corev1.LimitTypeContainer,
		DefaultRequest: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m")},
		Default:        corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("256Mi")}}}}}
	got := summarizeLimits(lr)
	if len(got) != 1 || !strings.Contains(got[0], "default request cpu 100m") || !strings.Contains(got[0], "default limit memory 256Mi") {
		t.Fatalf("%v", got)
	}
}

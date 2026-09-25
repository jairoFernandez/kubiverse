package main

import (
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestConfigRefsFromPods(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "payments", Name: "ledger-1"},
		Spec: corev1.PodSpec{
			ImagePullSecrets: []corev1.LocalObjectReference{{Name: "regcred"}},
			Volumes: []corev1.Volume{{Name: "cfg", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "ledger-config"}}}},
				{Name: "ca", VolumeSource: corev1.VolumeSource{Projected: &corev1.ProjectedVolumeSource{Sources: []corev1.VolumeProjection{{ConfigMap: &corev1.ConfigMapProjection{LocalObjectReference: corev1.LocalObjectReference{Name: "kube-root-ca.crt"}}}}}}}},
			Containers: []corev1.Container{{Name: "ledger", Env: []corev1.EnvVar{
				{Name: "DB_PASSWORD", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "db"}, Key: "password"}}},
				{Name: "DB_USER", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "db"}, Key: "user"}}},
			}, EnvFrom: []corev1.EnvFromSource{{SecretRef: &corev1.SecretEnvSource{LocalObjectReference: corev1.LocalObjectReference{Name: "stripe-key"}}}}}},
		},
		Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{{Name: "ledger", State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{
			Reason: "CreateContainerConfigError", Message: `secret "stripe-key" not found`}}}}},
	}
	b := &Bridge{}
	s := &Snapshot{Certs: []Cert{{Namespace: "payments", Name: "pay-tls", Secret: "pay-tls"}}}
	b.fillStorageAndConfig(s, []*corev1.Pod{pod}, time.Now())
	got := map[string]ConfigRef{}
	for _, c := range s.Configs {
		got[c.Kind+"/"+c.Name] = c
	}
	if db := got["Secret/db"]; len(db.Keys) != 2 || db.Keys[0] != "password" || db.How[0] != "env" || db.Pods[0] != "ledger-1" {
		t.Errorf("db: %+v", db)
	}
	if r := got["Secret/regcred"]; r.Type != "registry" {
		t.Errorf("regcred: %+v", r)
	}
	if r := got["Secret/stripe-key"]; r.Exists != "no" || len(r.Missing) != 1 {
		t.Errorf("stripe-key: %+v", r)
	}
	if r := got["Secret/pay-tls"]; r.Type != "tls" || r.Cert != "pay-tls" {
		t.Errorf("pay-tls: %+v", r)
	}
	if _, ok := got["ConfigMap/kube-root-ca.crt"]; ok {
		t.Error("kube-root-ca.crt is noise")
	}
	if r := got["ConfigMap/ledger-config"]; r.How[0] != "volume" || r.Exists != "unknown" {
		t.Errorf("ledger-config: %+v", r)
	}
}

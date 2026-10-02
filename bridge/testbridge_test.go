package main

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/tools/cache"
)

// newTestBridge: a Bridge over a fake clientset holding objs, with every
// lister buildSnapshot reads filled from the same objects (straight into the
// informers' stores: nothing runs in the background).
func newTestBridge(t *testing.T, objs ...runtime.Object) *Bridge {
	t.Helper()
	cs := fake.NewClientset(objs...)
	f := informers.NewSharedInformerFactory(cs, 0)
	b := &Bridge{cs: cs, contextName: "test", server: "https://127.0.0.1:6443", clients: map[*client]struct{}{}}
	b.nodeLister = f.Core().V1().Nodes().Lister()
	b.nsLister = f.Core().V1().Namespaces().Lister()
	b.podLister = f.Core().V1().Pods().Lister()
	b.svcLister = f.Core().V1().Services().Lister()
	b.depLister = f.Apps().V1().Deployments().Lister()
	b.rsLister = f.Apps().V1().ReplicaSets().Lister()
	b.stsLister = f.Apps().V1().StatefulSets().Lister()
	b.dsLister = f.Apps().V1().DaemonSets().Lister()
	b.ingLister = f.Networking().V1().Ingresses().Lister()
	b.ops.hpa = f.Autoscaling().V2().HorizontalPodAutoscalers().Lister()
	b.ops.pdb = f.Policy().V1().PodDisruptionBudgets().Lister()
	b.res.pvc = f.Core().V1().PersistentVolumeClaims().Lister()
	b.res.sc = f.Storage().V1().StorageClasses().Lister()
	b.res.netpol = f.Networking().V1().NetworkPolicies().Lister()
	b.res.quota = f.Core().V1().ResourceQuotas().Lister()
	b.res.limits = f.Core().V1().LimitRanges().Lister()
	b.store.pv = f.Core().V1().PersistentVolumes().Lister()
	for _, o := range objs {
		var inf cache.SharedIndexInformer
		switch o.(type) {
		case *corev1.Node:
			inf = f.Core().V1().Nodes().Informer()
		case *corev1.Namespace:
			inf = f.Core().V1().Namespaces().Informer()
		case *corev1.Pod:
			inf = f.Core().V1().Pods().Informer()
		case *corev1.Service:
			inf = f.Core().V1().Services().Informer()
		case *appsv1.Deployment:
			inf = f.Apps().V1().Deployments().Informer()
		case *appsv1.ReplicaSet:
			inf = f.Apps().V1().ReplicaSets().Informer()
		case *appsv1.StatefulSet:
			inf = f.Apps().V1().StatefulSets().Informer()
		case *appsv1.DaemonSet:
			inf = f.Apps().V1().DaemonSets().Informer()
		case *networkingv1.Ingress:
			inf = f.Networking().V1().Ingresses().Informer()
		case *networkingv1.NetworkPolicy:
			inf = f.Networking().V1().NetworkPolicies().Informer()
		case *autoscalingv2.HorizontalPodAutoscaler:
			inf = f.Autoscaling().V2().HorizontalPodAutoscalers().Informer()
		case *policyv1.PodDisruptionBudget:
			inf = f.Policy().V1().PodDisruptionBudgets().Informer()
		case *corev1.PersistentVolumeClaim:
			inf = f.Core().V1().PersistentVolumeClaims().Informer()
		case *corev1.PersistentVolume:
			inf = f.Core().V1().PersistentVolumes().Informer()
		case *storagev1.StorageClass:
			inf = f.Storage().V1().StorageClasses().Informer()
		case *corev1.ResourceQuota:
			inf = f.Core().V1().ResourceQuotas().Informer()
		case *corev1.LimitRange:
			inf = f.Core().V1().LimitRanges().Informer()
		default:
			continue // only in the clientset (events, ...)
		}
		if err := inf.GetIndexer().Add(o); err != nil {
			t.Fatalf("add %T: %v", o, err)
		}
	}
	return b
}

// Small builders for the objects the tests need.

func objMeta(ns, name string, created time.Time) metav1.ObjectMeta {
	return metav1.ObjectMeta{Namespace: ns, Name: name, CreationTimestamp: metav1.NewTime(created)}
}

func controller(kind, name string) []metav1.OwnerReference {
	return []metav1.OwnerReference{{Kind: kind, Name: name, Controller: ptr(true)}}
}

func runningPod(ns, name, node string, lbls map[string]string, ready bool) *corev1.Pod {
	st := corev1.ConditionFalse
	if ready {
		st = corev1.ConditionTrue
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name, Labels: lbls},
		Spec: corev1.PodSpec{NodeName: node, Containers: []corev1.Container{{Name: "app", Image: "nginx:1.27",
			Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: 8080}},
			Resources: corev1.ResourceRequirements{Requests: corev1.ResourceList{
				corev1.ResourceCPU: resource.MustParse("250m"), corev1.ResourceMemory: resource.MustParse("64Mi")}}}}},
		Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: "10.244.0.10",
			Conditions:        []corev1.PodCondition{{Type: corev1.PodReady, Status: st}},
			ContainerStatuses: []corev1.ContainerStatus{{Name: "app", Ready: ready, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}}},
	}
}

package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
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
	"k8s.io/apimachinery/pkg/util/intstr"
)

var t0 = time.Unix(1_700_000_000, 0)

// A small but complete cluster: what buildSnapshot reads, in every shape the
// game cares about.
func snapshotFixture() []runtime.Object {
	helmMeta := func(ns, name, release, chart string) metav1.ObjectMeta {
		m := objMeta(ns, name, t0)
		m.Labels = map[string]string{"helm.sh/chart": chart, "app.kubernetes.io/managed-by": "Helm"}
		m.Annotations = map[string]string{"meta.helm.sh/release-name": release}
		return m
	}
	apiDep := &appsv1.Deployment{ObjectMeta: objMeta("shop", "api", t0.Add(time.Hour)),
		Spec: appsv1.DeploymentSpec{Replicas: ptr(int32(3)), Paused: true,
			Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "api"}},
				Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "api", Image: "shop/api:2"}}}}},
		Status: appsv1.DeploymentStatus{ReadyReplicas: 2, UpdatedReplicas: 1, AvailableReplicas: 2}}
	apiDep.Annotations = map[string]string{"deployment.kubernetes.io/revision": "4", "argocd.argoproj.io/tracking-id": "shop:apps/Deployment:shop/api"}
	redis := &appsv1.StatefulSet{ObjectMeta: helmMeta("shop", "redis-master", "redis", "redis-17.3.2"),
		Spec:   appsv1.StatefulSetSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Image: "redis:7"}}}}},
		Status: appsv1.StatefulSetStatus{ReadyReplicas: 1, UpdatedReplicas: 1, AvailableReplicas: 1}}
	exporter := &appsv1.DaemonSet{ObjectMeta: helmMeta("monitoring", "node-exporter", "kps", "prometheus-node-exporter-4.39.0"),
		Spec:   appsv1.DaemonSetSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Image: "prom/node-exporter:1.8"}}}}},
		Status: appsv1.DaemonSetStatus{DesiredNumberScheduled: 2, NumberReady: 1, UpdatedNumberScheduled: 2, NumberAvailable: 1}}

	worker := &corev1.Node{ObjectMeta: objMeta("", "worker-b", t0),
		Spec: corev1.NodeSpec{Unschedulable: true, Taints: []corev1.Taint{{Key: "gpu", Value: "true", Effect: corev1.TaintEffectNoSchedule}, {Key: "dedicated", Effect: corev1.TaintEffectNoExecute}}},
		Status: corev1.NodeStatus{
			Capacity:    corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4"), corev1.ResourceMemory: resource.MustParse("8Gi"), corev1.ResourcePods: resource.MustParse("110")},
			Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("3500m"), corev1.ResourceMemory: resource.MustParse("7Gi")},
			Conditions:  []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionFalse}, {Type: corev1.NodeMemoryPressure, Status: corev1.ConditionTrue}, {Type: corev1.NodeDiskPressure, Status: corev1.ConditionFalse}},
			NodeInfo:    corev1.NodeSystemInfo{KubeletVersion: "v1.33.1", OperatingSystem: "linux", Architecture: "arm64"}}}
	cp := &corev1.Node{ObjectMeta: objMeta("", "control-plane", t0), Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}}}
	cp.Labels = map[string]string{"node-role.kubernetes.io/control-plane": "", "node-role.kubernetes.io/etcd": "", "kubernetes.io/os": "linux"}

	rs := &appsv1.ReplicaSet{ObjectMeta: objMeta("shop", "api-7d9f", t0)}
	rs.OwnerReferences = controller("Deployment", "api")
	api1 := runningPod("shop", "api-7d9f-a", "worker-b", map[string]string{"app": "api"}, true)
	api1.OwnerReferences = controller("ReplicaSet", "api-7d9f")
	api1.Spec.Volumes = []corev1.Volume{{Name: "data", VolumeSource: corev1.VolumeSource{PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "uploads"}}},
		{Name: "cfg", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "api-config"}}}}}
	api2 := runningPod("shop", "api-7d9f-b", "worker-b", map[string]string{"app": "api"}, false)
	api2.OwnerReferences = controller("ReplicaSet", "api-7d9f")
	api2.Status.ContainerStatuses[0].RestartCount = 4
	api2.Status.ContainerStatuses[0].State = corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff", Message: "back-off 5m0s restarting failed container"}}
	pending := &corev1.Pod{ObjectMeta: objMeta("shop", "redis-master-0", t0), Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "redis", Image: "redis:7"}}},
		Status: corev1.PodStatus{Phase: corev1.PodPending, Conditions: []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionFalse, Message: "0/2 nodes are available: 1 Insufficient memory"}}}}
	pending.OwnerReferences = controller("StatefulSet", "redis-master")
	orphan := runningPod("default", "debug", "control-plane", nil, true)

	web := &corev1.Service{ObjectMeta: helmMeta("shop", "api", "shop-chart", "shop-1.0.0"),
		Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer, ClusterIP: "10.96.0.12", Selector: map[string]string{"app": "api"},
			ExternalIPs: []string{"192.0.2.10"},
			Ports:       []corev1.ServicePort{{Port: 80, Protocol: corev1.ProtocolTCP, NodePort: 30080, TargetPort: intstr.FromString("http")}}},
		Status: corev1.ServiceStatus{LoadBalancer: corev1.LoadBalancerStatus{Ingress: []corev1.LoadBalancerIngress{{IP: "198.51.100.7"}, {Hostname: "lb.example.com"}}}}}
	headless := &corev1.Service{ObjectMeta: objMeta("default", "kubernetes", t0), Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeClusterIP, ClusterIP: "10.96.0.1",
		Ports: []corev1.ServicePort{{Port: 443, Protocol: corev1.ProtocolTCP}}}}

	ing := &networkingv1.Ingress{ObjectMeta: objMeta("shop", "web", t0),
		Spec: networkingv1.IngressSpec{IngressClassName: ptr("nginx"),
			DefaultBackend: &networkingv1.IngressBackend{Service: &networkingv1.IngressServiceBackend{Name: "api", Port: networkingv1.ServiceBackendPort{Number: 80}}},
			TLS:            []networkingv1.IngressTLS{{Hosts: []string{"shop.example.com"}}},
			Rules: []networkingv1.IngressRule{
				{Host: "shop.example.com", IngressRuleValue: networkingv1.IngressRuleValue{HTTP: &networkingv1.HTTPIngressRuleValue{Paths: []networkingv1.HTTPIngressPath{
					{Path: "", Backend: networkingv1.IngressBackend{Service: &networkingv1.IngressServiceBackend{Name: "api", Port: networkingv1.ServiceBackendPort{Name: "http"}}}},
					{Path: "/static", Backend: networkingv1.IngressBackend{Resource: &corev1.TypedLocalObjectReference{Kind: "Bucket", Name: "assets"}}}}}}},
				{Host: "no-http.example.com"}}},
		Status: networkingv1.IngressStatus{LoadBalancer: networkingv1.IngressLoadBalancerStatus{Ingress: []networkingv1.IngressLoadBalancerIngress{{IP: "198.51.100.8"}, {Hostname: "ing.example.com"}}}}}

	hpa := &autoscalingv2.HorizontalPodAutoscaler{ObjectMeta: objMeta("shop", "api", t0),
		Spec: autoscalingv2.HorizontalPodAutoscalerSpec{ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{Kind: "Deployment", Name: "api"}, MinReplicas: ptr(int32(2)), MaxReplicas: 6}}
	pdb := &policyv1.PodDisruptionBudget{ObjectMeta: objMeta("shop", "api", t0),
		Spec:   policyv1.PodDisruptionBudgetSpec{MinAvailable: ptr(intstr.FromInt32(2)), Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "api"}}},
		Status: policyv1.PodDisruptionBudgetStatus{DisruptionsAllowed: 0}}
	pvc := &corev1.PersistentVolumeClaim{ObjectMeta: objMeta("shop", "uploads", t0),
		Spec: corev1.PersistentVolumeClaimSpec{StorageClassName: ptr("fast"), VolumeName: "pv-1", AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
			Resources: corev1.VolumeResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")}}},
		Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimBound, Capacity: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")}}}
	pv := &corev1.PersistentVolume{ObjectMeta: objMeta("", "pv-1", t0),
		Spec: corev1.PersistentVolumeSpec{StorageClassName: "fast", PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimDelete,
			Capacity: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("10Gi")}, ClaimRef: &corev1.ObjectReference{Namespace: "shop", Name: "uploads"},
			PersistentVolumeSource: corev1.PersistentVolumeSource{CSI: &corev1.CSIPersistentVolumeSource{Driver: "ebs.csi.aws.com"}}},
		Status: corev1.PersistentVolumeStatus{Phase: corev1.VolumeBound}}
	sc := &storagev1.StorageClass{ObjectMeta: objMeta("", "fast", t0), Provisioner: "ebs.csi.aws.com",
		ReclaimPolicy: ptr(corev1.PersistentVolumeReclaimDelete), VolumeBindingMode: ptr(storagev1.VolumeBindingWaitForFirstConsumer), AllowVolumeExpansion: ptr(true)}
	sc.Annotations = map[string]string{"storageclass.kubernetes.io/is-default-class": "true"}
	np := &networkingv1.NetworkPolicy{ObjectMeta: objMeta("shop", "deny-all", t0),
		Spec: networkingv1.NetworkPolicySpec{PodSelector: metav1.LabelSelector{MatchLabels: map[string]string{"app": "api"}}, PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress}}}
	quota := &corev1.ResourceQuota{ObjectMeta: objMeta("shop", "team", t0),
		Status: corev1.ResourceQuotaStatus{Hard: corev1.ResourceList{corev1.ResourcePods: resource.MustParse("10")}, Used: corev1.ResourceList{corev1.ResourcePods: resource.MustParse("3")}}}
	limits := &corev1.LimitRange{ObjectMeta: objMeta("shop", "defaults", t0),
		Spec: corev1.LimitRangeSpec{Limits: []corev1.LimitRangeItem{{Type: corev1.LimitTypeContainer, Default: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("500m")}}}}}

	return []runtime.Object{
		&corev1.Namespace{ObjectMeta: objMeta("", "shop", t0.Add(2*time.Hour)), Status: corev1.NamespaceStatus{Phase: corev1.NamespaceActive}},
		&corev1.Namespace{ObjectMeta: objMeta("", "default", t0), Status: corev1.NamespaceStatus{Phase: corev1.NamespaceActive}},
		&corev1.Namespace{ObjectMeta: objMeta("", "monitoring", t0), Status: corev1.NamespaceStatus{Phase: corev1.NamespaceTerminating}},
		worker, cp, rs, api1, api2, pending, orphan, apiDep, redis, exporter, web, headless, ing, hpa, pdb, pvc, pv, sc, np, quota, limits,
	}
}

func TestBuildSnapshot(t *testing.T) {
	b := newTestBridge(t, snapshotFixture()...)
	b.readOnly = true
	b.obs.alerts = []Alert{{ID: "a1", Name: "KubePodCrashLooping", Severity: "warning", NS: "shop"}}
	s, err := b.buildSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	assertSnapshotInvariants(t, s)
	if s.Context != "test" || !s.ReadOnly || s.Time == 0 || len(s.Alerts) != 1 {
		t.Errorf("header: %+v", s)
	}

	// Nodes: sorted, roles from labels, taints in words, abnormal conditions.
	if len(s.Nodes) != 2 || s.Nodes[0].Name != "control-plane" {
		t.Fatalf("nodes: %+v", s.Nodes)
	}
	cpn, w := s.Nodes[0], s.Nodes[1]
	if !cpn.Ready || strings.Join(cpn.Roles, ",") != "control-plane,etcd" {
		t.Errorf("control-plane: %+v", cpn)
	}
	if w.Ready || !w.Unschedulable || w.CPU != "4" || w.Memory != "8Gi" || w.PodCapacity != 110 || w.CPUm != 3500 || w.MemBytes != 7<<30 ||
		w.Kubelet != "v1.33.1" || w.Arch != "arm64" || len(w.Roles) != 0 {
		t.Errorf("worker: %+v", w)
	}
	if strings.Join(w.Taints, " ") != "gpu=true:NoSchedule dedicated:NoExecute" || strings.Join(w.Conditions, ",") != "MemoryPressure" {
		t.Errorf("taints/conditions: %v %v", w.Taints, w.Conditions)
	}

	// Namespaces: sorted, with phase and creation time (+ quota, limits, policies).
	if len(s.Namespaces) != 3 || s.Namespaces[2].Name != "shop" || s.Namespaces[2].Created != t0.Add(2*time.Hour).Unix() || s.Namespaces[1].Phase != "Terminating" {
		t.Fatalf("namespaces: %+v", s.Namespaces)
	}
	shop := s.Namespaces[2]
	if len(shop.NetPols) != 1 || shop.NetPols[0].Name != "deny-all" || len(shop.Quota) != 1 || shop.Quota[0].Pct != 30 || len(shop.Limits) == 0 {
		t.Errorf("shop policies: %+v", shop)
	}

	// Pods: sorted by ns/name, owners resolved through the ReplicaSet.
	pods := map[string]Pod{}
	for _, p := range s.Pods {
		pods[p.Namespace+"/"+p.Name] = p
	}
	if len(s.Pods) != 4 || s.Pods[0].Name != "debug" {
		t.Fatalf("pods: %+v", s.Pods)
	}
	a := pods["shop/api-7d9f-a"]
	if a.OwnerKind != "Deployment" || a.OwnerName != "api" || a.Status != "Running" || a.Ready != 1 || a.Total != 1 ||
		a.CPUReqm != 250 || a.MemReq != 64<<20 || a.Images[0] != "nginx:1.27" || strings.Join(a.NetPols, ",") != "deny-all" {
		t.Errorf("api-a: %+v", a)
	}
	if c := pods["shop/api-7d9f-b"]; c.Status != "CrashLoopBackOff" || c.Restarts != 4 || c.Ready != 0 || !strings.Contains(c.Message, "back-off") {
		t.Errorf("crashing pod: %+v", c)
	}
	if p := pods["shop/redis-master-0"]; p.OwnerKind != "StatefulSet" || p.Status != "Pending" || !strings.Contains(p.Message, "Insufficient memory") {
		t.Errorf("pending pod: %+v", p)
	}
	if o := pods["default/debug"]; o.OwnerKind != "" || len(o.NetPols) != 0 {
		t.Errorf("bare pod: %+v", o)
	}

	// Workloads: the three kinds, sorted ns/kind/name, with HPA, PDB, GitOps, Helm.
	wl := map[string]Workload{}
	for _, x := range s.Workloads {
		wl[x.Kind+"/"+x.Name] = x
	}
	if len(s.Workloads) != 3 || s.Workloads[0].Kind != "DaemonSet" {
		t.Fatalf("workloads: %+v", s.Workloads)
	}
	d := wl["Deployment/api"]
	if d.Desired != 3 || d.Ready != 2 || d.Updated != 1 || d.Available != 2 || d.Image != "shop/api:2" || !d.Paused || d.Revision != 4 ||
		d.Created != t0.Add(time.Hour).Unix() || d.Release != "" || d.Chart != "" {
		t.Errorf("deployment: %+v", d)
	}
	if d.GitOps == nil || d.GitOps.Tool != "argocd" || d.HPA == nil || d.HPA.Max != 6 || d.PDB == nil || d.PDB.MinAvailable != "2" {
		t.Errorf("deployment owners: gitops=%+v hpa=%+v pdb=%+v", d.GitOps, d.HPA, d.PDB)
	}
	if st := wl["StatefulSet/redis-master"]; st.Desired != 1 || st.Ready != 1 || st.Release != "redis" || st.Chart != "redis-17.3.2" || st.Created != t0.Unix() {
		t.Errorf("statefulset (nil replicas = 1): %+v", st)
	}
	if ds := wl["DaemonSet/node-exporter"]; ds.Desired != 2 || ds.Ready != 1 || ds.Updated != 2 || ds.Release != "kps" || ds.Chart != "prometheus-node-exporter-4.39.0" {
		t.Errorf("daemonset: %+v", ds)
	}

	// Services: ports, node ports, external addresses, the pods behind them.
	if len(s.Services) != 2 || s.Services[0].Name != "kubernetes" {
		t.Fatalf("services: %+v", s.Services)
	}
	sv := s.Services[1]
	if sv.Type != "LoadBalancer" || sv.Ports[0] != "80/TCP" || sv.NodePorts[0] != 30080 ||
		strings.Join(sv.External, ",") != "198.51.100.7,lb.example.com,192.0.2.10" ||
		strings.Join(sv.Pods, ",") != "api-7d9f-a,api-7d9f-b" || sv.Ready != 1 {
		t.Errorf("service: %+v", sv)
	}
	if k := s.Services[0]; len(k.Pods) != 0 || k.Pods == nil {
		t.Errorf("no selector: no pods, but an empty list (JSON []): %+v", k)
	}

	// Ingress: default backend, named and numbered ports, "" path = "/", TLS, address.
	if len(s.Ingresses) != 1 {
		t.Fatalf("ingresses: %+v", s.Ingresses)
	}
	in := s.Ingresses[0]
	want := []IngressRule{{"", "/*", "api", "80"}, {"shop.example.com", "/", "api", "http"}, {"shop.example.com", "/static", "", ""}}
	if in.Class != "nginx" || len(in.Rules) != len(want) || strings.Join(in.TLS, ",") != "shop.example.com" || strings.Join(in.Address, ",") != "198.51.100.8,ing.example.com" {
		t.Fatalf("ingress: %+v", in)
	}
	for i := range want {
		if in.Rules[i] != want[i] {
			t.Errorf("rule %d: %+v, want %+v", i, in.Rules[i], want[i])
		}
	}

	// Helm releases from the objects' labels.
	rels := map[string]bool{}
	for _, r := range s.Helm {
		rels[r.Namespace+"/"+r.Name] = true
	}
	if !rels["shop/redis"] || !rels["monitoring/kps"] || !rels["shop/shop-chart"] || len(s.Helm) != 3 {
		t.Errorf("helm: %+v", s.Helm)
	}

	// Storage: the claim (who mounts it), its class and its volume.
	if len(s.Volumes) != 1 || s.Volumes[0].Class != "fast" || s.Volumes[0].Capacity != "10Gi" || s.Volumes[0].Request != "10Gi" ||
		strings.Join(s.Volumes[0].Access, ",") != "RWO" || strings.Join(s.Volumes[0].Pods, ",") != "api-7d9f-a" {
		t.Errorf("volumes: %+v", s.Volumes)
	}
	if len(s.StorageClasses) != 1 || !s.StorageClasses[0].Default || !s.StorageClasses[0].Expand || s.StorageClasses[0].Binding != "WaitForFirstConsumer" {
		t.Errorf("storage classes: %+v", s.StorageClasses)
	}
	if len(s.PVs) != 1 || s.PVs[0].Claim != "shop/uploads" || s.PVs[0].Source != "ebs.csi.aws.com" || s.PVs[0].Capacity != "10Gi" {
		t.Errorf("pvs: %+v", s.PVs)
	}
	if len(s.Configs) != 1 || s.Configs[0].Kind != "ConfigMap" || s.Configs[0].Name != "api-config" {
		t.Errorf("configs: %+v", s.Configs)
	}

	// The game reads lists, never JSON nulls, for the collections it iterates.
	raw, _ := json.Marshal(s)
	for _, k := range []string{`"alerts":null`, `"ingresses":null`, `"volumes":null`, `"apps":null`, `"certs":null`, `"pvs":null`, `"configs":null`} {
		if strings.Contains(string(raw), k) {
			t.Errorf("%s in the snapshot", k)
		}
	}
}

// An empty cluster (and no Ingress permission) still gives a usable snapshot.
func TestBuildSnapshotEmpty(t *testing.T) {
	b := newTestBridge(t)
	b.ingLister = nil
	s, err := b.buildSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	assertSnapshotInvariants(t, s)
	if s.Alerts == nil || s.Ingresses == nil || len(s.Pods) != 0 || len(s.Workloads) != 0 || s.Helm == nil || s.ChartRepos == nil {
		t.Errorf("empty snapshot: %+v", s)
	}
	// /api/state serves the same thing.
	rec := httptest.NewRecorder()
	b.handleState(rec, httptest.NewRequest("GET", "/api/state", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"context":"test"`) {
		t.Errorf("/api/state: %d %s", rec.Code, rec.Body.String())
	}
	if got := b.namespaceSummary("nowhere"); !strings.Contains(got, "no pods") {
		t.Errorf("namespace summary: %q", got)
	}
}

func TestPodStatusInit(t *testing.T) {
	waiting := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodPending, InitContainerStatuses: []corev1.ContainerStatus{
		{State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "ImagePullBackOff"}}}}}}
	failed := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodPending, InitContainerStatuses: []corev1.ContainerStatus{
		{State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 1}}}}}}
	evicted := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodFailed, Reason: "Evicted"}}
	done := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodSucceeded, ContainerStatuses: []corev1.ContainerStatus{
		{State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{Reason: "Completed", Message: "bye"}}}}}}
	for p, want := range map[*corev1.Pod]string{waiting: "Init:ImagePullBackOff", failed: "Init:Error", evicted: "Evicted", done: "Completed"} {
		if got := podStatus(p); got != want {
			t.Errorf("podStatus = %q, want %q", got, want)
		}
	}
	if m := convertPod(done, nil, time.Now()).Message; m != "bye" {
		t.Errorf("terminated message: %q", m)
	}
	gone := runningPod("a", "b", "n", nil, true)
	gone.DeletionTimestamp = &metav1.Time{Time: time.Now()}
	if podReady(gone) || podStatus(gone) != "Terminating" {
		t.Error("a pod being deleted is not ready")
	}
}

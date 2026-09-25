package main

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	authorizationv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	networkinglisters "k8s.io/client-go/listers/networking/v1"
	storagelisters "k8s.io/client-go/listers/storage/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

// The resources beyond workloads: storage (PVCs, StorageClasses), network
// policies, quotas and limits, and the most common CRDs (Argo CD
// Applications, cert-manager Certificates, Gateway API routes). Each one is
// optional: what the bridge may not list simply isn't shown.

// Volume is a PersistentVolumeClaim and who mounts it.
type Volume struct {
	Namespace string   `json:"ns"`
	Name      string   `json:"name"`
	Status    string   `json:"status"` // Bound | Pending | Lost
	Capacity  string   `json:"capacity"`
	Request   string   `json:"request"`
	Class     string   `json:"class"`
	Access    []string `json:"access"`
	Volume    string   `json:"volume"` // the PV
	Pods      []string `json:"pods"`
	Age       int64    `json:"age"`
	Used      int64    `json:"used,omitempty"`     // bytes (kubelet stats via Prometheus)
	UsedPct   float64  `json:"used_pct,omitempty"` // of its capacity
}

type StorageClass struct {
	Name        string `json:"name"`
	Provisioner string `json:"provisioner"`
	Reclaim     string `json:"reclaim"`
	Binding     string `json:"binding"` // Immediate | WaitForFirstConsumer
	Default     bool   `json:"default"`
	Expand      bool   `json:"expand"`
}

// NetPol summarises a NetworkPolicy in words.
type NetPol struct {
	Name     string   `json:"name"`
	Selects  string   `json:"selects"` // "all pods" or "app=web"
	Types    []string `json:"types"`
	DenyIn   bool     `json:"deny_in"`  // selected pods accept no traffic at all
	DenyOut  bool     `json:"deny_out"` // selected pods can't send any
	Ingress  []string `json:"ingress"`
	Egress   []string `json:"egress"`
	selector labels.Selector
}

// QuotaItem: one line of a ResourceQuota.
type QuotaItem struct {
	Quota    string  `json:"quota"`
	Resource string  `json:"resource"`
	Used     string  `json:"used"`
	Hard     string  `json:"hard"`
	Pct      float64 `json:"pct"`
}

// ArgoApp: an Argo CD Application.
type ArgoApp struct {
	Namespace string `json:"ns"`
	Name      string `json:"name"`
	Project   string `json:"project"`
	Repo      string `json:"repo"`
	Path      string `json:"path"`
	Revision  string `json:"revision"`
	DestNS    string `json:"dest_ns"`
	Sync      string `json:"sync"`   // Synced | OutOfSync | Unknown
	Health    string `json:"health"` // Healthy | Progressing | Degraded | Missing | Suspended
	Operation string `json:"operation,omitempty"`
	Message   string `json:"message,omitempty"`
	AutoSync  bool   `json:"auto_sync"`
	SelfHeal  bool   `json:"self_heal"`
}

// Cert: a cert-manager Certificate.
type Cert struct {
	Namespace string   `json:"ns"`
	Name      string   `json:"name"`
	Secret    string   `json:"secret"`
	DNS       []string `json:"dns"`
	Issuer    string   `json:"issuer"`
	Ready     bool     `json:"ready"`
	Message   string   `json:"message,omitempty"`
	ExpiresIn int64    `json:"expires_in"` // seconds; 0 = unknown
}

type resListers struct {
	pvc    corelisters.PersistentVolumeClaimLister
	sc     storagelisters.StorageClassLister
	netpol networkinglisters.NetworkPolicyLister
	quota  corelisters.ResourceQuotaLister
	limits corelisters.LimitRangeLister
	dyn    map[string]cache.GenericLister // "apps", "certs", "routes", "gateways"
}

var (
	gvrApps     = schema.GroupVersionResource{Group: "argoproj.io", Version: "v1alpha1", Resource: "applications"}
	gvrCerts    = schema.GroupVersionResource{Group: "cert-manager.io", Version: "v1", Resource: "certificates"}
	gvrRoutes   = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "httproutes"}
	gvrGateways = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways"}
)

// addResources probes what may be listed and registers its informers.
func (b *Bridge) addResources(ctx context.Context, f informers.SharedInformerFactory, cs kubernetes.Interface, cfg *rest.Config, onChange cache.ResourceEventHandler) {
	probe, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	one := metav1.ListOptions{Limit: 1}
	add := func(inf cache.SharedIndexInformer) { _, _ = inf.AddEventHandler(onChange) }
	if _, err := cs.CoreV1().PersistentVolumeClaims("").List(probe, one); err == nil {
		b.res.pvc = f.Core().V1().PersistentVolumeClaims().Lister()
		add(f.Core().V1().PersistentVolumeClaims().Informer())
	}
	if _, err := cs.StorageV1().StorageClasses().List(probe, one); err == nil {
		b.res.sc = f.Storage().V1().StorageClasses().Lister()
		add(f.Storage().V1().StorageClasses().Informer())
	}
	if _, err := cs.NetworkingV1().NetworkPolicies("").List(probe, one); err == nil {
		b.res.netpol = f.Networking().V1().NetworkPolicies().Lister()
		add(f.Networking().V1().NetworkPolicies().Informer())
	}
	if _, err := cs.CoreV1().ResourceQuotas("").List(probe, one); err == nil {
		b.res.quota = f.Core().V1().ResourceQuotas().Lister()
		add(f.Core().V1().ResourceQuotas().Informer())
	}
	if _, err := cs.CoreV1().LimitRanges("").List(probe, one); err == nil {
		b.res.limits = f.Core().V1().LimitRanges().Lister()
		add(f.Core().V1().LimitRanges().Informer())
	}
	// CRDs: only if installed and listable.
	dc, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return
	}
	df := dynamicinformer.NewDynamicSharedInformerFactory(dc, 10*time.Minute)
	b.res.dyn = map[string]cache.GenericLister{}
	for key, gvr := range map[string]schema.GroupVersionResource{"apps": gvrApps, "certs": gvrCerts, "routes": gvrRoutes, "gateways": gvrGateways} {
		if _, err := dc.Resource(gvr).List(probe, one); err != nil {
			continue
		}
		gi := df.ForResource(gvr)
		add(gi.Informer())
		b.res.dyn[key] = gi.Lister()
	}
	df.Start(ctx.Done())
}

func (b *Bridge) dynList(key string) []*unstructured.Unstructured {
	l := b.res.dyn[key]
	if l == nil {
		return nil
	}
	objs, _ := l.List(labels.Everything())
	out := make([]*unstructured.Unstructured, 0, len(objs))
	for _, o := range objs {
		if u, ok := o.(*unstructured.Unstructured); ok {
			out = append(out, u)
		}
	}
	return out
}

// fillResources adds the resources above to a snapshot (pods: the raw ones,
// for their labels and volumes).
func (b *Bridge) fillResources(s *Snapshot, pods []*corev1.Pod, now time.Time) {
	s.Volumes, s.StorageClasses, s.Apps, s.Certs = []Volume{}, []StorageClass{}, []ArgoApp{}, []Cert{}
	// Who mounts each PVC.
	users := map[string][]string{}
	for _, p := range pods {
		for _, v := range p.Spec.Volumes {
			if v.PersistentVolumeClaim != nil {
				k := p.Namespace + "/" + v.PersistentVolumeClaim.ClaimName
				users[k] = append(users[k], p.Name)
			}
		}
	}
	if b.res.pvc != nil {
		list, _ := b.res.pvc.List(labels.Everything())
		for _, c := range list {
			v := Volume{Namespace: c.Namespace, Name: c.Name, Status: string(c.Status.Phase), Volume: c.Spec.VolumeName,
				Pods: users[c.Namespace+"/"+c.Name], Age: int64(now.Sub(c.CreationTimestamp.Time).Seconds()), Access: []string{}}
			if q, ok := c.Status.Capacity[corev1.ResourceStorage]; ok {
				v.Capacity = q.String()
			}
			if q, ok := c.Spec.Resources.Requests[corev1.ResourceStorage]; ok {
				v.Request = q.String()
			}
			if c.Spec.StorageClassName != nil {
				v.Class = *c.Spec.StorageClassName
			}
			for _, m := range c.Spec.AccessModes {
				v.Access = append(v.Access, map[corev1.PersistentVolumeAccessMode]string{"ReadWriteOnce": "RWO", "ReadOnlyMany": "ROX", "ReadWriteMany": "RWX", "ReadWriteOncePod": "RWOP"}[m])
			}
			if v.Pods == nil {
				v.Pods = []string{}
			}
			s.Volumes = append(s.Volumes, v)
		}
		sort.Slice(s.Volumes, func(i, j int) bool {
			return s.Volumes[i].Namespace+"/"+s.Volumes[i].Name < s.Volumes[j].Namespace+"/"+s.Volumes[j].Name
		})
	}
	if b.res.sc != nil {
		list, _ := b.res.sc.List(labels.Everything())
		for _, c := range list {
			sc := StorageClass{Name: c.Name, Provisioner: c.Provisioner, Default: c.Annotations["storageclass.kubernetes.io/is-default-class"] == "true"}
			if c.ReclaimPolicy != nil {
				sc.Reclaim = string(*c.ReclaimPolicy)
			}
			if c.VolumeBindingMode != nil {
				sc.Binding = string(*c.VolumeBindingMode)
			}
			if c.AllowVolumeExpansion != nil {
				sc.Expand = *c.AllowVolumeExpansion
			}
			s.StorageClasses = append(s.StorageClasses, sc)
		}
		sort.Slice(s.StorageClasses, func(i, j int) bool { return s.StorageClasses[i].Name < s.StorageClasses[j].Name })
	}
	// Per namespace: policies, quotas, limits.
	byNS := map[string]*Namespace{}
	for i := range s.Namespaces {
		byNS[s.Namespaces[i].Name] = &s.Namespaces[i]
	}
	pols := map[string][]NetPol{}
	if b.res.netpol != nil {
		list, _ := b.res.netpol.List(labels.Everything())
		for _, np := range list {
			pols[np.Namespace] = append(pols[np.Namespace], summarizeNetPol(np))
		}
		for ns, l := range pols {
			sort.Slice(l, func(i, j int) bool { return l[i].Name < l[j].Name })
			if n := byNS[ns]; n != nil {
				n.NetPols = l
			}
		}
		// Which policies select each pod.
		podPols := map[string][]string{}
		for _, p := range pods {
			for _, np := range pols[p.Namespace] {
				if np.selector != nil && np.selector.Matches(labels.Set(p.Labels)) {
					podPols[p.Namespace+"/"+p.Name] = append(podPols[p.Namespace+"/"+p.Name], np.Name)
				}
			}
		}
		for i := range s.Pods {
			s.Pods[i].NetPols = podPols[s.Pods[i].Namespace+"/"+s.Pods[i].Name]
		}
	}
	if b.res.quota != nil {
		list, _ := b.res.quota.List(labels.Everything())
		for _, q := range list {
			n := byNS[q.Namespace]
			if n == nil {
				continue
			}
			for res, hard := range q.Status.Hard {
				used := q.Status.Used[res]
				it := QuotaItem{Quota: q.Name, Resource: string(res), Used: used.String(), Hard: hard.String()}
				if hard.MilliValue() > 0 {
					it.Pct = float64(used.MilliValue()) / float64(hard.MilliValue()) * 100
				}
				n.Quota = append(n.Quota, it)
			}
			sort.Slice(n.Quota, func(i, j int) bool { return n.Quota[i].Resource < n.Quota[j].Resource })
		}
	}
	if b.res.limits != nil {
		list, _ := b.res.limits.List(labels.Everything())
		for _, lr := range list {
			if n := byNS[lr.Namespace]; n != nil {
				n.Limits = append(n.Limits, summarizeLimits(lr)...)
			}
		}
	}
	s.Apps = b.argoApps()
	s.Certs = b.certs(now)
	s.Ingresses = append(s.Ingresses, b.gatewayRoutes()...)
}

func summarizeNetPol(np *networkingv1.NetworkPolicy) NetPol {
	out := NetPol{Name: np.Name, Types: []string{}, Ingress: []string{}, Egress: []string{}}
	sel, err := metav1.LabelSelectorAsSelector(&np.Spec.PodSelector)
	if err == nil {
		out.selector = sel
	}
	if sel == nil || sel.Empty() {
		out.Selects = "all pods"
	} else {
		out.Selects = sel.String()
	}
	types := np.Spec.PolicyTypes
	if len(types) == 0 { // the API's default
		types = []networkingv1.PolicyType{networkingv1.PolicyTypeIngress}
		if len(np.Spec.Egress) > 0 {
			types = append(types, networkingv1.PolicyTypeEgress)
		}
	}
	for _, t := range types {
		out.Types = append(out.Types, string(t))
		switch t {
		case networkingv1.PolicyTypeIngress:
			out.DenyIn = len(np.Spec.Ingress) == 0
		case networkingv1.PolicyTypeEgress:
			out.DenyOut = len(np.Spec.Egress) == 0
		}
	}
	for _, r := range np.Spec.Ingress {
		out.Ingress = append(out.Ingress, "from "+peers(r.From)+ports(r.Ports))
	}
	for _, r := range np.Spec.Egress {
		out.Egress = append(out.Egress, "to "+peers(r.To)+ports(r.Ports))
	}
	return out
}

func peers(ps []networkingv1.NetworkPolicyPeer) string {
	if len(ps) == 0 {
		return "anywhere"
	}
	var parts []string
	for _, p := range ps {
		var bits []string
		if p.NamespaceSelector != nil {
			if s, err := metav1.LabelSelectorAsSelector(p.NamespaceSelector); err == nil && !s.Empty() {
				bits = append(bits, "namespaces "+s.String())
			} else {
				bits = append(bits, "all namespaces")
			}
		}
		if p.PodSelector != nil {
			if s, err := metav1.LabelSelectorAsSelector(p.PodSelector); err == nil && !s.Empty() {
				bits = append(bits, "pods "+s.String())
			} else if p.NamespaceSelector == nil {
				bits = append(bits, "pods of this namespace")
			}
		}
		if p.IPBlock != nil {
			b := p.IPBlock.CIDR
			if len(p.IPBlock.Except) > 0 {
				b += " except " + strings.Join(p.IPBlock.Except, ",")
			}
			bits = append(bits, b)
		}
		parts = append(parts, strings.Join(bits, " "))
	}
	return strings.Join(parts, "; ")
}

func ports(ps []networkingv1.NetworkPolicyPort) string {
	if len(ps) == 0 {
		return ""
	}
	var out []string
	for _, p := range ps {
		s := ""
		if p.Port != nil {
			s = p.Port.String()
		}
		if p.Protocol != nil && *p.Protocol != corev1.ProtocolTCP {
			s += "/" + string(*p.Protocol)
		}
		if s != "" {
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return ""
	}
	return " on " + strings.Join(out, ",")
}

func summarizeLimits(lr *corev1.LimitRange) []string {
	var out []string
	for _, l := range lr.Spec.Limits {
		var bits []string
		add := func(what string, rl corev1.ResourceList) {
			var s []string
			for _, r := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
				if q, ok := rl[r]; ok {
					s = append(s, string(r)+" "+q.String())
				}
			}
			if len(s) > 0 {
				bits = append(bits, what+" "+strings.Join(s, ", "))
			}
		}
		add("default request", l.DefaultRequest)
		add("default limit", l.Default)
		add("max", l.Max)
		add("min", l.Min)
		if len(bits) > 0 {
			out = append(out, fmt.Sprintf("%s (%s): %s", l.Type, lr.Name, strings.Join(bits, "; ")))
		}
	}
	return out
}

func (b *Bridge) argoApps() []ArgoApp {
	out := []ArgoApp{}
	for _, u := range b.dynList("apps") {
		a := ArgoApp{Namespace: u.GetNamespace(), Name: u.GetName()}
		a.Project, _, _ = unstructured.NestedString(u.Object, "spec", "project")
		a.DestNS, _, _ = unstructured.NestedString(u.Object, "spec", "destination", "namespace")
		a.Repo, _, _ = unstructured.NestedString(u.Object, "spec", "source", "repoURL")
		a.Path, _, _ = unstructured.NestedString(u.Object, "spec", "source", "path")
		if a.Repo == "" { // multi-source apps
			if srcs, ok, _ := unstructured.NestedSlice(u.Object, "spec", "sources"); ok && len(srcs) > 0 {
				if m, ok := srcs[0].(map[string]any); ok {
					a.Repo, _ = m["repoURL"].(string)
					a.Path, _ = m["path"].(string)
				}
			}
		}
		a.Revision, _, _ = unstructured.NestedString(u.Object, "status", "sync", "revision")
		a.Sync, _, _ = unstructured.NestedString(u.Object, "status", "sync", "status")
		a.Health, _, _ = unstructured.NestedString(u.Object, "status", "health", "status")
		a.Operation, _, _ = unstructured.NestedString(u.Object, "status", "operationState", "phase")
		a.Message, _, _ = unstructured.NestedString(u.Object, "status", "operationState", "message")
		if a.Message == "" {
			a.Message, _, _ = unstructured.NestedString(u.Object, "status", "health", "message")
		}
		a.Message = redact(a.Message)
		_, a.AutoSync, _ = unstructured.NestedMap(u.Object, "spec", "syncPolicy", "automated")
		a.SelfHeal, _, _ = unstructured.NestedBool(u.Object, "spec", "syncPolicy", "automated", "selfHeal")
		if len(a.Revision) > 10 {
			a.Revision = a.Revision[:10]
		}
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Namespace+"/"+out[i].Name < out[j].Namespace+"/"+out[j].Name })
	return out
}

func (b *Bridge) certs(now time.Time) []Cert {
	out := []Cert{}
	for _, u := range b.dynList("certs") {
		c := Cert{Namespace: u.GetNamespace(), Name: u.GetName()}
		c.Secret, _, _ = unstructured.NestedString(u.Object, "spec", "secretName")
		c.DNS, _, _ = unstructured.NestedStringSlice(u.Object, "spec", "dnsNames")
		kind, _, _ := unstructured.NestedString(u.Object, "spec", "issuerRef", "kind")
		name, _, _ := unstructured.NestedString(u.Object, "spec", "issuerRef", "name")
		c.Issuer = strings.TrimPrefix(kind+"/"+name, "/")
		conds, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
		for _, x := range conds {
			m, _ := x.(map[string]any)
			if m["type"] == "Ready" {
				c.Ready = m["status"] == "True"
				c.Message, _ = m["message"].(string)
			}
		}
		if na, ok, _ := unstructured.NestedString(u.Object, "status", "notAfter"); ok {
			if t, err := time.Parse(time.RFC3339, na); err == nil {
				c.ExpiresIn = int64(t.Sub(now).Seconds())
			}
		}
		if c.DNS == nil {
			c.DNS = []string{}
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Namespace+"/"+out[i].Name < out[j].Namespace+"/"+out[j].Name })
	return out
}

// gatewayRoutes turns Gateway API HTTPRoutes into the same shape as
// Ingresses, so the Internet city draws them too.
func (b *Bridge) gatewayRoutes() []Ingress {
	addr := map[string][]string{} // gateway ns/name -> addresses
	for _, g := range b.dynList("gateways") {
		as, _, _ := unstructured.NestedSlice(g.Object, "status", "addresses")
		for _, a := range as {
			if m, ok := a.(map[string]any); ok {
				if v, ok := m["value"].(string); ok {
					addr[g.GetNamespace()+"/"+g.GetName()] = append(addr[g.GetNamespace()+"/"+g.GetName()], v)
				}
			}
		}
	}
	var out []Ingress
	for _, r := range b.dynList("routes") {
		ing := Ingress{Namespace: r.GetNamespace(), Name: "httproute/" + r.GetName(), Class: "gateway", Rules: []IngressRule{}, TLS: []string{}, Address: []string{}}
		parents, _, _ := unstructured.NestedSlice(r.Object, "spec", "parentRefs")
		for _, p := range parents {
			if m, ok := p.(map[string]any); ok {
				gns, _ := m["namespace"].(string)
				if gns == "" {
					gns = r.GetNamespace()
				}
				gname, _ := m["name"].(string)
				ing.Class = "gateway " + gname
				ing.Address = append(ing.Address, addr[gns+"/"+gname]...)
			}
		}
		hosts, _, _ := unstructured.NestedStringSlice(r.Object, "spec", "hostnames")
		if len(hosts) == 0 {
			hosts = []string{""}
		}
		rules, _, _ := unstructured.NestedSlice(r.Object, "spec", "rules")
		for _, rr := range rules {
			rm, _ := rr.(map[string]any)
			paths := []string{"/"}
			if ms, ok := rm["matches"].([]any); ok && len(ms) > 0 {
				paths = nil
				for _, mm := range ms {
					if m, ok := mm.(map[string]any); ok {
						if pm, ok := m["path"].(map[string]any); ok {
							v, _ := pm["value"].(string)
							paths = append(paths, v)
						}
					}
				}
				if len(paths) == 0 {
					paths = []string{"/"}
				}
			}
			refs, _ := rm["backendRefs"].([]any)
			for _, ref := range refs {
				bm, _ := ref.(map[string]any)
				svc, _ := bm["name"].(string)
				port := ""
				if pv, ok := bm["port"]; ok {
					port = fmt.Sprint(pv)
				}
				for _, h := range hosts {
					for _, p := range paths {
						ing.Rules = append(ing.Rules, IngressRule{Host: h, Path: p, Service: svc, Port: port})
					}
				}
			}
		}
		out = append(out, ing)
	}
	return out
}

// GET /api/cani?ns=: what the player may do in a namespace (their own
// permissions: impersonated in team mode), from a SelfSubjectRulesReview.
func (b *Bridge) handleCanI(w http.ResponseWriter, r *http.Request) {
	ns := r.URL.Query().Get("ns")
	if !dnsName.MatchString(ns) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "bad namespace"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	rev, err := b.clientFor(r.Context()).AuthorizationV1().SelfSubjectRulesReviews().Create(ctx,
		&authorizationv1.SelfSubjectRulesReview{Spec: authorizationv1.SelfSubjectRulesReviewSpec{Namespace: ns}}, metav1.CreateOptions{})
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	rules := rev.Status.ResourceRules
	checks := []map[string]any{}
	for _, c := range canChecks {
		checks = append(checks, map[string]any{"what": c.what, "ok": allowed(rules, c.verb, c.group, c.resource), "cmd": fmt.Sprintf("kubectl auth can-i %s %s -n %s", c.verb, c.resource, ns)})
	}
	who := identityFrom(r.Context()).User
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "user": who, "checks": checks, "incomplete": rev.Status.Incomplete})
}

var canChecks = []struct{ what, verb, group, resource string }{
	{"see pods", "list", "", "pods"},
	{"read logs", "get", "", "pods/log"},
	{"exec into pods", "create", "", "pods/exec"},
	{"delete pods", "delete", "", "pods"},
	{"scale / edit deployments", "patch", "apps", "deployments"},
	{"create deployments", "create", "apps", "deployments"},
	{"edit services", "patch", "", "services"},
	{"read configmaps", "get", "", "configmaps"},
	{"read secrets", "get", "", "secrets"},
	{"port-forward", "create", "", "pods/portforward"},
}

// allowed evaluates resource rules the way RBAC does (with its wildcards).
func allowed(rules []authorizationv1.ResourceRule, verb, group, resource string) bool {
	has := func(list []string, v string) bool {
		for _, x := range list {
			if x == "*" || x == v {
				return true
			}
		}
		return false
	}
	for _, r := range rules {
		if has(r.Verbs, verb) && has(r.APIGroups, group) && has(r.Resources, resource) && len(r.ResourceNames) == 0 {
			return true
		}
	}
	return false
}

package main

import (
	"context"
	"encoding/json"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/metadata/metadatainformer"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

// Storage and configuration, drawn as things you can see:
//   - PersistentVolumes stand in the storage yard of the plant, each claim's
//     tank in its hall is piped to them, and to the pods that mount it; the
//     level is the real use (kubelet volume stats, when Prometheus has them).
//   - Secrets are safes and ConfigMaps filing cabinets in each hall's vault,
//     with cables to the pods that use them and a drawer per key they read.
//
// Values are never read. What a pod uses comes from its own spec; whether a
// Secret or ConfigMap exists comes from a metadata-only list (the API server
// sends names and dates, not data), with every annotation dropped on arrival
// (kubectl's last-applied annotation would carry the data).

// PV is a PersistentVolume.
type PV struct {
	Name     string `json:"name"`
	Capacity string `json:"capacity"`
	Class    string `json:"class"`
	Reclaim  string `json:"reclaim"`
	Status   string `json:"status"` // Available | Bound | Released | Failed
	Claim    string `json:"claim"`  // "ns/name"
	Source   string `json:"source"` // csi driver, hostPath, nfs, local...
	Age      int64  `json:"age"`
}

// ConfigRef is a Secret or ConfigMap as the pods see it.
type ConfigRef struct {
	Kind      string   `json:"kind"` // Secret | ConfigMap
	Namespace string   `json:"ns"`
	Name      string   `json:"name"`
	Type      string   `json:"type"`              // tls | registry | opaque (Secrets)
	Keys      []string `json:"keys"`              // the keys pods read by name (env)
	Pods      []string `json:"pods"`              // who uses it
	How       []string `json:"how"`               // volume, env, envFrom, imagePull
	Exists    string   `json:"exists"`            // yes | no | unknown (not allowed to list names)
	Missing   []string `json:"missing,omitempty"` // pods that can't start without it
	Age       int64    `json:"age,omitempty"`
	Cert      string   `json:"cert,omitempty"` // the cert-manager Certificate that writes it
}

type storeListers struct {
	pv         corelisters.PersistentVolumeLister
	secretMeta cache.GenericLister // names only
	cmMeta     cache.GenericLister
}

// addStorageAndConfig registers the PV informer and the metadata-only
// informers for Secrets and ConfigMaps, when allowed.
func (b *Bridge) addStorageAndConfig(ctx context.Context, f informers.SharedInformerFactory, cs kubernetes.Interface, cfg *rest.Config, onChange cache.ResourceEventHandler) {
	probe, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	one := metav1.ListOptions{Limit: 1}
	if _, err := cs.CoreV1().PersistentVolumes().List(probe, one); err == nil {
		b.store.pv = f.Core().V1().PersistentVolumes().Lister()
		_, _ = f.Core().V1().PersistentVolumes().Informer().AddEventHandler(onChange)
	}
	mc, err := metadata.NewForConfig(cfg)
	if err != nil {
		return
	}
	mf := metadatainformer.NewSharedInformerFactory(mc, 10*time.Minute)
	for _, it := range []struct {
		res    string
		lister *cache.GenericLister
	}{{"secrets", &b.store.secretMeta}, {"configmaps", &b.store.cmMeta}} {
		gvr := schema.GroupVersionResource{Version: "v1", Resource: it.res}
		if _, err := mc.Resource(gvr).List(probe, one); err != nil {
			continue
		}
		gi := mf.ForResource(gvr)
		inf := gi.Informer()
		_ = inf.SetTransform(func(obj any) (any, error) {
			if m, ok := obj.(*metav1.PartialObjectMetadata); ok {
				m.Annotations, m.ManagedFields, m.Labels = nil, nil, nil
			}
			return obj, nil
		})
		_, _ = inf.AddEventHandler(onChange)
		*it.lister = gi.Lister()
	}
	mf.Start(ctx.Done())
}

var missingRef = regexp.MustCompile(`(secret|configmap)s? "([^"]+)" not found`)

// noise: things every pod or tool has that would only clutter the vault.
func noiseConfig(kind, name string) bool {
	if kind == "ConfigMap" {
		return name == "kube-root-ca.crt" || name == "openshift-service-ca.crt" || strings.HasSuffix(name, "-lock") || strings.HasSuffix(name, "-leader-election")
	}
	return strings.HasPrefix(name, "sh.helm.release.") || strings.Contains(name, "-token-")
}

// fillStorageAndConfig adds PVs, volume use and the config refs to a snapshot.
func (b *Bridge) fillStorageAndConfig(s *Snapshot, pods []*corev1.Pod, now time.Time) {
	s.PVs, s.Configs = []PV{}, []ConfigRef{}
	if b.store.pv != nil {
		list, _ := b.store.pv.List(labels.Everything())
		for _, v := range list {
			p := PV{Name: v.Name, Class: v.Spec.StorageClassName, Reclaim: string(v.Spec.PersistentVolumeReclaimPolicy),
				Status: string(v.Status.Phase), Age: int64(now.Sub(v.CreationTimestamp.Time).Seconds())}
			if q, ok := v.Spec.Capacity[corev1.ResourceStorage]; ok {
				p.Capacity = q.String()
			}
			if v.Spec.ClaimRef != nil {
				p.Claim = v.Spec.ClaimRef.Namespace + "/" + v.Spec.ClaimRef.Name
			}
			switch src := v.Spec.PersistentVolumeSource; {
			case src.CSI != nil:
				p.Source = src.CSI.Driver
			case src.HostPath != nil:
				p.Source = "hostPath"
			case src.Local != nil:
				p.Source = "local"
			case src.NFS != nil:
				p.Source = "nfs " + src.NFS.Server
			default:
				p.Source = "in-tree"
			}
			s.PVs = append(s.PVs, p)
		}
		sort.Slice(s.PVs, func(i, j int) bool { return s.PVs[i].Name < s.PVs[j].Name })
	}
	// Real use of each claim, from the kubelet's volume stats (Prometheus).
	use := b.volumeUse()
	for i := range s.Volumes {
		if u, ok := use[s.Volumes[i].Namespace+"/"+s.Volumes[i].Name]; ok && u[1] > 0 {
			s.Volumes[i].Used = int64(u[0])
			s.Volumes[i].UsedPct = u[0] / u[1] * 100
		}
	}
	// Secrets and ConfigMaps, from what the pods use.
	refs := map[string]*ConfigRef{}
	get := func(kind, ns, name string) *ConfigRef {
		k := kind + "/" + ns + "/" + name
		r := refs[k]
		if r == nil {
			r = &ConfigRef{Kind: kind, Namespace: ns, Name: name, Keys: []string{}, Pods: []string{}, How: []string{}, Exists: "unknown"}
			if kind == "Secret" {
				r.Type = "opaque"
			}
			refs[k] = r
		}
		return r
	}
	use1 := func(r *ConfigRef, pod, how, key string) {
		if !contains(r.Pods, pod) {
			r.Pods = append(r.Pods, pod)
		}
		if !contains(r.How, how) {
			r.How = append(r.How, how)
		}
		if key != "" && !contains(r.Keys, key) {
			r.Keys = append(r.Keys, key)
		}
	}
	for _, p := range pods {
		for _, v := range p.Spec.Volumes {
			if v.Secret != nil {
				use1(get("Secret", p.Namespace, v.Secret.SecretName), p.Name, "volume", "")
			}
			if v.ConfigMap != nil {
				use1(get("ConfigMap", p.Namespace, v.ConfigMap.Name), p.Name, "volume", "")
			}
			if v.Projected != nil {
				for _, src := range v.Projected.Sources {
					if src.Secret != nil {
						use1(get("Secret", p.Namespace, src.Secret.Name), p.Name, "volume", "")
					}
					if src.ConfigMap != nil && !noiseConfig("ConfigMap", src.ConfigMap.Name) {
						use1(get("ConfigMap", p.Namespace, src.ConfigMap.Name), p.Name, "volume", "")
					}
				}
			}
		}
		for _, c := range append(append([]corev1.Container{}, p.Spec.InitContainers...), p.Spec.Containers...) {
			for _, e := range c.Env {
				if e.ValueFrom == nil {
					continue
				}
				if r := e.ValueFrom.SecretKeyRef; r != nil {
					use1(get("Secret", p.Namespace, r.Name), p.Name, "env", r.Key)
				}
				if r := e.ValueFrom.ConfigMapKeyRef; r != nil {
					use1(get("ConfigMap", p.Namespace, r.Name), p.Name, "env", r.Key)
				}
			}
			for _, e := range c.EnvFrom {
				if e.SecretRef != nil {
					use1(get("Secret", p.Namespace, e.SecretRef.Name), p.Name, "envFrom", "")
				}
				if e.ConfigMapRef != nil {
					use1(get("ConfigMap", p.Namespace, e.ConfigMapRef.Name), p.Name, "envFrom", "")
				}
			}
		}
		for _, ips := range p.Spec.ImagePullSecrets {
			r := get("Secret", p.Namespace, ips.Name)
			r.Type = "registry"
			use1(r, p.Name, "imagePull", "")
		}
		// "secret "x" not found": the pod can't start without it.
		for _, st := range append(append([]corev1.ContainerStatus{}, p.Status.InitContainerStatuses...), p.Status.ContainerStatuses...) {
			if w := st.State.Waiting; w != nil {
				for _, m := range missingRef.FindAllStringSubmatch(w.Message, -1) {
					kind := map[string]string{"secret": "Secret", "configmap": "ConfigMap"}[m[1]]
					r := get(kind, p.Namespace, m[2])
					if !contains(r.Missing, p.Name) {
						r.Missing = append(r.Missing, p.Name)
					}
				}
			}
		}
	}
	// TLS: the secrets cert-manager and Ingresses use.
	for _, c := range s.Certs {
		if c.Secret != "" {
			r := get("Secret", c.Namespace, c.Secret)
			r.Type, r.Cert = "tls", c.Name
		}
	}
	for _, sn := range b.ingressTLSSecrets() {
		get("Secret", sn[0], sn[1]).Type = "tls"
	}
	// Which exist (names only), and the ones nobody uses.
	for kind, l := range map[string]cache.GenericLister{"Secret": b.store.secretMeta, "ConfigMap": b.store.cmMeta} {
		if l == nil {
			continue
		}
		objs, _ := l.List(labels.Everything())
		seen := map[string]bool{}
		for _, o := range objs {
			m, ok := o.(*metav1.PartialObjectMetadata)
			if !ok {
				continue
			}
			k := kind + "/" + m.Namespace + "/" + m.Name
			seen[k] = true
			if r := refs[k]; r != nil {
				r.Exists, r.Age = "yes", int64(now.Sub(m.CreationTimestamp.Time).Seconds())
			} else if !noiseConfig(kind, m.Name) && !strings.HasPrefix(m.Namespace, "kube-") {
				r := get(kind, m.Namespace, m.Name)
				r.Exists, r.Age = "yes", int64(now.Sub(m.CreationTimestamp.Time).Seconds())
			}
		}
		for k, r := range refs {
			if strings.HasPrefix(k, kind+"/") && !seen[k] {
				r.Exists = "no"
			}
		}
	}
	for _, r := range refs {
		if len(r.Missing) > 0 {
			r.Exists = "no"
		}
		if noiseConfig(r.Kind, r.Name) {
			continue
		}
		sort.Strings(r.Keys)
		sort.Strings(r.Pods)
		s.Configs = append(s.Configs, *r)
	}
	sort.Slice(s.Configs, func(i, j int) bool {
		a, c := s.Configs[i], s.Configs[j]
		return a.Namespace+"/"+a.Kind+"/"+a.Name < c.Namespace+"/"+c.Kind+"/"+c.Name
	})
}

// ingressTLSSecrets: [ns, secretName] of every Ingress TLS block.
func (b *Bridge) ingressTLSSecrets() [][2]string {
	if b.ingLister == nil {
		return nil
	}
	var out [][2]string
	list, _ := b.ingLister.List(labels.Everything())
	for _, ing := range list {
		for _, t := range ing.Spec.TLS {
			if t.SecretName != "" {
				out = append(out, [2]string{ing.Namespace, t.SecretName})
			}
		}
	}
	return out
}

// volumeUse: "ns/claim" -> [used bytes, capacity bytes], refreshed with the
// alerts (every 30 s) when Prometheus has the kubelet's volume stats.
func (b *Bridge) volumeUse() map[string][2]float64 {
	b.obs.mu.Lock()
	defer b.obs.mu.Unlock()
	return b.obs.volUse
}

func (b *Bridge) fetchVolumeUse(ctx context.Context) {
	if !b.discover()["prometheus"].ok() {
		return
	}
	out := map[string][2]float64{}
	for i, q := range []string{"max by(namespace,persistentvolumeclaim) (kubelet_volume_stats_used_bytes)", "max by(namespace,persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes)"} {
		raw, err := b.obsGet(ctx, "prometheus", "/api/v1/query", url.Values{"query": {q}})
		if err != nil {
			return
		}
		var res struct {
			Data struct {
				Result []struct {
					Metric map[string]string `json:"metric"`
					Value  [2]any            `json:"value"`
				} `json:"result"`
			} `json:"data"`
		}
		if json.Unmarshal(raw, &res) != nil {
			return
		}
		for _, r := range res.Data.Result {
			k := r.Metric["namespace"] + "/" + r.Metric["persistentvolumeclaim"]
			sv, _ := r.Value[1].(string)
			f, _ := strconv.ParseFloat(sv, 64)
			v := out[k]
			v[i] = f
			out[k] = v
		}
	}
	b.obs.mu.Lock()
	b.obs.volUse = out
	b.obs.mu.Unlock()
	if len(out) > 0 {
		b.markDirty()
	}
}

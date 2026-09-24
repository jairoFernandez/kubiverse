class_name Weapons
## Chaos-mode arsenal. Each weapon is a real Kubernetes operation; new ones
## are unlocked by completing the missions that teach that concept.

const LIST := [
	{"id": "blaster", "name": "Pod blaster", "target": "pod", "color": Color("ffec27"), "unlock": "", "cooldown": 0.25,
		"desc": "Deletes the pod you hit (its controller recreates it)."},
	{"id": "hammer", "name": "Rollout hammer", "target": "workload", "color": Color("c98bff"), "unlock": "rollout", "cooldown": 0.8,
		"desc": "Rolling restart of the workload you hit."},
	{"id": "ray", "name": "Shrink ray", "target": "workload", "color": Color("29adff"), "unlock": "escala", "cooldown": 0.7,
		"desc": "Scales the workload you hit down by one replica."},
	{"id": "freeze", "name": "Freeze gun", "target": "node", "color": Color("a8e6ff"), "unlock": "mantenimiento", "cooldown": 0.6,
		"desc": "Cordons the node you hit (hit again to uncordon)."},
	{"id": "cutter", "name": "Service cutter", "target": "service", "color": Color("ff77a8"), "unlock": "trafico", "cooldown": 0.8,
		"desc": "Deletes the Service (loading dock) you hit."},
	{"id": "nuke", "name": "Nuke", "target": "workload", "color": Color("ff004d"), "unlock": "limpieza", "cooldown": 2.0,
		"desc": "Deletes the whole workload you hit and all its pods."},
]


static func unlocked(i: int) -> bool:
	var u: String = LIST[i].unlock
	return u == "" or u in Settings.missions_done


## Mission title that unlocks weapon i (for the "locked" hint).
static func unlock_title(i: int) -> String:
	for m in Missions.LIST:
		if m.id == LIST[i].unlock:
			return m.title
	return ""

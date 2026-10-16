# Stopgap: import MasterChef (PL) episodes that Sonarr leaves import-blocked.
#
# Releases from the Polish tracker are named "MasterChef.Poland...", which Sonarr
# cannot match to the series title (it only knows "MasterChef (PL)" plus the
# scene-mapping alias "Masterchef"), so every episode stops in the queue with
# "release was matched to series by ID. Automatic import is not possible".
# A scene-mapping alias was requested on 2026-10-15 via the Servarr form; once
# the devs add it this script is no longer needed.
#
# Run from the workstation (no sudo needed on the NAS, it reads the API key via
# docker exec):
#   ssh nas.local python3 - < ansible/roles/media_server/files/scripts/sonarr_masterchef_import.py
#
# Safe to re-run: only touches queue items for the series below whose state is
# importBlocked and whose manual-import preview maps cleanly to an episode.
import json, subprocess

SERIES_ID = 179  # MasterChef (PL)

KEY = subprocess.check_output(["docker","exec","sonarr","sed","-n",r"s/.*<ApiKey>\([^<]*\)<.*/\1/p","/config/config.xml"]).decode().strip()

def api(method, path, body=None):
    cmd=["curl","-s","-X",method,"-H","X-Api-Key: "+KEY,"-H","Content-Type: application/json",f"http://localhost:8989/api/v3/{path}"]
    if body is not None: cmd += ["-d", json.dumps(body)]
    out=subprocess.check_output(cmd).decode()
    return json.loads(out) if out.strip() else None

queue=api("GET","queue?pageSize=500")["records"]
blocked={r["downloadId"] for r in queue if r.get("seriesId")==SERIES_ID and r.get("trackedDownloadState")=="importBlocked"}
files=[]
for dl in sorted(blocked):
    for m in api("GET",f"manualimport?downloadId={dl}"):
        if not m.get("series") or m["series"]["id"]!=SERIES_ID or not m.get("episodes") or m.get("rejections"):
            print("  skip", m["relativePath"][:70], [x["reason"][:50] for x in m.get("rejections",[])]); continue
        files.append({"path":m["path"],"seriesId":SERIES_ID,"episodeIds":[e["id"] for e in m["episodes"]],
                      "quality":m["quality"],"languages":m["languages"],"releaseGroup":m.get("releaseGroup"),"downloadId":dl})
        print("  import", m["relativePath"][:70], "->", ["S%02dE%02d"%(m["seasonNumber"],e["episodeNumber"]) for e in m["episodes"]])
if files:
    c=api("POST","command",{"name":"ManualImport","files":files,"importMode":"auto"})
    print("manual import command", c["id"], c["status"])
else:
    print("nothing blocked for MasterChef (PL)")

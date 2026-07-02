#!/usr/bin/env bash
#
# pod-mem.sh — zestawienie podów: pamięć requestowana vs faktycznie używana.
#
# Łączy `kubectl top pods` (faktyczne zużycie) z requestami z manifestów
# i wypluwa jedną tabelę: NAMESPACE  POD  REQUEST(Mi)  USAGE(Mi)  USE%  (LIMIT opcjonalnie).
#
# Wymaga: kubectl, jq, metrics-server (dla `kubectl top`).
#
# Użycie:
#   ./pod-mem.sh                 # wszystkie namespace'y, sort po USE% malejąco
#   ./pod-mem.sh -n argocd       # tylko jeden namespace
#   ./pod-mem.sh -l              # pokaż też kolumnę LIMIT i LIM%
#   ./pod-mem.sh --sort under    # sort: najbardziej przewymiarowane (niski USE%) na górze
#   ./pod-mem.sh --csv > out.csv # wyjście CSV (np. do Excela)
#
set -euo pipefail

NS_ARG="-A"
SHOW_LIMIT=0
SORT_MODE="over"   # over = najwyższy USE% na górze; under = najniższy USE% na górze
FORMAT="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS_ARG="-n $2"; shift 2 ;;
    -A|--all-namespaces) NS_ARG="-A"; shift ;;
    -l|--limit) SHOW_LIMIT=1; shift ;;
    --sort) SORT_MODE="$2"; shift 2 ;;
    --csv) FORMAT="csv"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Nieznany argument: $1" >&2; exit 1 ;;
  esac
done

# --- 1. Faktyczne zużycie z metrics-servera ---
# kubectl top pods -A  ->  NAMESPACE NAME CPU MEM ; -n ns -> NAME CPU MEM
usage="$(kubectl top pods $NS_ARG --no-headers 2>/dev/null || true)"
if [[ -z "$usage" ]]; then
  echo "BŁĄD: 'kubectl top pods' nic nie zwrócił. Czy działa metrics-server?" >&2
  exit 1
fi

# --- 2. Requesty i limity z manifestów (suma po kontenerach w podzie) ---
requests="$(kubectl get pods $NS_ARG -o json | jq -r '
  .items[] |
  .metadata.namespace as $ns | .metadata.name as $pod |
  ( [ .spec.containers[].resources.requests.memory // "0" ] | join(" ") ) as $req |
  ( [ .spec.containers[].resources.limits.memory   // "0" ] | join(" ") ) as $lim |
  "\($ns)\t\($pod)\tREQ\t\($req)\tLIM\t\($lim)"
')"

# --- 3. Join + konwersja jednostek + sortowanie, wszystko w awk ---
# Czy 'top' ma kolumnę namespace? (-A tak, -n nie)
HAS_NS=0; [[ "$NS_ARG" == "-A" ]] && HAS_NS=1

out="$({ echo "$requests"; echo "---USAGE---"; echo "$usage"; } | awk -v HAS_NS="$HAS_NS" \
  -v SHOW_LIMIT="$SHOW_LIMIT" -v SORT_MODE="$SORT_MODE" -v FORMAT="$FORMAT" '
function to_mi(q,   n,u) {
  if (q == "" || q == "0") return 0
  if (q ~ /Ki$/) { n=q; sub(/Ki$/,"",n); return n/1024 }
  if (q ~ /Mi$/) { n=q; sub(/Mi$/,"",n); return n }
  if (q ~ /Gi$/) { n=q; sub(/Gi$/,"",n); return n*1024 }
  if (q ~ /Ti$/) { n=q; sub(/Ti$/,"",n); return n*1024*1024 }
  if (q ~ /m$/)  { n=q; sub(/m$/,"",n);  return n/1000/1024/1024 }   # millibytes (rzadkie)
  if (q ~ /k$/||q ~ /K$/) { n=q; sub(/[kK]$/,"",n); return n*1000/1024/1024 }
  if (q ~ /M$/)  { n=q; sub(/M$/,"",n);  return n*1000*1000/1024/1024 }
  if (q ~ /G$/)  { n=q; sub(/G$/,"",n);  return n*1000*1000*1000/1024/1024 }
  n=q; sub(/[^0-9.].*$/,"",n); return n/1024/1024   # gołe bajty
}
BEGIN { mode="req" }
/^---USAGE---$/ { mode="use"; next }
mode=="req" {
  # format: ns \t pod \t REQ \t r1 r2 ... \t LIM \t l1 l2 ...
  ns=$1; pod=$2
  key=ns "/" pod
  # pola po "REQ" do "LIM" = requesty; po "LIM" = limity
  rsum=0; lsum=0; seen=0
  for (i=3;i<=NF;i++) {
    if ($i=="REQ") { seen=1; continue }
    if ($i=="LIM") { seen=2; continue }
    if (seen==1) rsum += to_mi($i)
    if (seen==2) lsum += to_mi($i)
  }
  req[key]=rsum; lim[key]=lsum; nsk[key]=ns; podk[key]=pod
  next
}
mode=="use" {
  if (HAS_NS==1) { ns=$1; pod=$2; mem=$4 } else { ns="-"; pod=$1; mem=$3 }
  key = (HAS_NS==1 ? ns "/" pod : pod)
  # gdy top jest -n, klucze z requests mają prawdziwy ns; dopasuj po podzie
  if (HAS_NS==0) {
    for (k in podk) if (podk[k]==pod) { key=k; ns=nsk[k]; break }
  }
  use[key]=to_mi(mem); nsk[key]=ns; podk[key]=pod
  haskey[key]=1
}
END {
  # nagłówek
  if (SHOW_LIMIT==1) hdr_l="\tLIMIT(Mi)\tLIM%"; else hdr_l=""
  n=0
  for (k in haskey) {
    r=(k in req)?req[k]:0; u=use[k]; l=(k in lim)?lim[k]:0
    pct = (r>0)? (u/r*100):0
    lpct= (l>0)? (u/l*100):0
    n++
    NSc[n]=nsk[k]; PODc[n]=podk[k]; Rc[n]=r; Uc[n]=u; Lc[n]=l; Pc[n]=pct; LPc[n]=lpct
  }
  # sort wg USE% (over: malejąco, under: rosnąco). Bąbelkowo - liczba podów mała.
  for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) {
    swap=0
    if (SORT_MODE=="under") { if (Pc[j] < Pc[i]) swap=1 } else { if (Pc[j] > Pc[i]) swap=1 }
    if (swap) {
      t=NSc[i];NSc[i]=NSc[j];NSc[j]=t; t=PODc[i];PODc[i]=PODc[j];PODc[j]=t
      t=Rc[i];Rc[i]=Rc[j];Rc[j]=t; t=Uc[i];Uc[i]=Uc[j];Uc[j]=t
      t=Lc[i];Lc[i]=Lc[j];Lc[j]=t; t=Pc[i];Pc[i]=Pc[j];Pc[j]=t; t=LPc[i];LPc[i]=LPc[j];LPc[j]=t
    }
  }
  if (FORMAT=="csv") {
    printf "NAMESPACE,POD,REQUEST_Mi,USAGE_Mi,USE_PCT"
    if (SHOW_LIMIT==1) printf ",LIMIT_Mi,LIM_PCT"
    printf "\n"
    for (i=1;i<=n;i++) {
      printf "%s,%s,%.0f,%.0f,%.0f", NSc[i],PODc[i],Rc[i],Uc[i],Pc[i]
      if (SHOW_LIMIT==1) printf ",%.0f,%.0f", Lc[i],LPc[i]
      printf "\n"
    }
  } else {
    if (SHOW_LIMIT==1)
      printf "%s %s %s %s %s %s %s\n","NAMESPACE","POD","REQ(Mi)","USE(Mi)","USE%","LIM(Mi)","LIM%"
    else
      printf "%s %s %s %s %s\n","NAMESPACE","POD","REQ(Mi)","USE(Mi)","USE%"
    for (i=1;i<=n;i++) {
      if (SHOW_LIMIT==1)
        printf "%s %s %.0f %.0f %.0f%% %.0f %.0f%%\n",NSc[i],PODc[i],Rc[i],Uc[i],Pc[i],Lc[i],LPc[i]
      else
        printf "%s %s %.0f %.0f %.0f%%\n",NSc[i],PODc[i],Rc[i],Uc[i],Pc[i]
    }
  }
}')"

if [[ "$FORMAT" == "table" ]]; then
  echo "$out" | column -t
else
  echo "$out"
fi

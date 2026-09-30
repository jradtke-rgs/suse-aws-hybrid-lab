#!/usr/bin/env python3
"""Check the rke2 / Rancher / cert-manager version pinning against reality.

Three versions in this lab are coupled, and getting the pairing wrong costs
a full bootstrap cycle to discover:

  rke2_version          decides the Kubernetes version on the node
  rancher_version       its Helm chart declares a kubeVersion ceiling
  cert_manager_version  supports a rolling window of Kubernetes releases

`helm install rancher` refuses the chart outright when the node's Kubernetes
version is above the ceiling - roughly twelve minutes into a bootstrap that
otherwise looked fine. This reads the published chart index rather than
trusting a comment in a .tf file, because the ceiling moves with every
Rancher release and the comment will not.

Reads index.yaml on stdin. No third-party modules: pyyaml is not installed
everywhere, and the two fields needed here are trivially line-addressable.
"""

import argparse
import re
import sys

VERSION_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")
CONSTRAINT_RE = re.compile(r"(<=|>=|<|>|=)\s*v?(\d+\.\d+(?:\.\d+)?)")


def parse_version(text):
    """'v1.36.4+rke2r1' -> (1, 36, 4). None when unparseable."""
    if not text:
        return None
    match = VERSION_RE.search(text)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3) or 0))


def parse_index(stream):
    """Yield (chart_version, kube_version_constraint) for the rancher chart.

    index.yaml nests exactly two levels deep for what is needed here: chart
    names at indent 2, one list item per release at indent 2 ("  - "), and
    that release's fields at indent 4. Anchoring on those indents matters -
    a release block contains its own nested lists (keywords, maintainers,
    urls), and treating any "- " line as a new release loses every field
    that follows one.
    """
    in_rancher = False
    version = None
    kube = None

    for raw in stream:
        line = raw.rstrip("\n")

        # "  <chartname>:" - a new chart's entry list begins.
        if re.match(r"^ {2}[A-Za-z0-9_.-]+:\s*$", line):
            if in_rancher and version:
                yield version, kube
            version, kube = None, None
            in_rancher = line.strip() == "rancher:"
            continue

        if not in_rancher:
            continue

        # "  - " at exactly indent 2 - a new release block.
        if line.startswith("  - ") and not line.startswith("    "):
            if version:
                yield version, kube
            version, kube = None, None
            line = "    " + line[4:]

        # "    key: value" at exactly indent 4 - a field of this release.
        field = re.match(r"^ {4}([A-Za-z0-9_]+):(.*)$", line)
        if not field:
            continue
        key, value = field.group(1), field.group(2).strip().strip('"')
        if key == "version":
            version = value
        elif key == "kubeVersion":
            kube = value

    if in_rancher and version:
        yield version, kube


def satisfies(kube_tuple, constraint):
    """Does this Kubernetes version satisfy a Helm kubeVersion constraint?

    Handles the forms Rancher actually publishes: '< 1.37.0-0',
    '>= 1.28.0-0 < 1.37.0-0'. Returns None when the constraint cannot be read,
    so an unrecognised form reports 'unknown' rather than a false pass.
    """
    clauses = CONSTRAINT_RE.findall(constraint or "")
    if not clauses:
        return None
    for operator, raw in clauses:
        bound = parse_version(raw)
        if bound is None:
            return None
        if operator == "<" and not kube_tuple < bound:
            return False
        if operator == "<=" and not kube_tuple <= bound:
            return False
        if operator == ">" and not kube_tuple > bound:
            return False
        if operator == ">=" and not kube_tuple >= bound:
            return False
        if operator == "=" and kube_tuple != bound:
            return False
    return True


GREEN, RED, YELLOW, OFF = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
if not sys.stderr.isatty():
    GREEN = RED = YELLOW = OFF = ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rke2", default="")
    parser.add_argument("--rancher", default="")
    parser.add_argument("--cert-manager", default="")
    args = parser.parse_args()

    charts = list(parse_index(sys.stdin))
    if not charts:
        print("could not parse the chart index", file=sys.stderr)
        return 1

    by_version = {version: kube for version, kube in charts}
    latest = charts[0][0] if charts else None

    kube = parse_version(args.rke2)
    if kube is None:
        print(f"{YELLOW}rke2_version is not pinned{OFF}")
        print("  Latest stable RKE2 is published faster than Rancher raises its ceiling,")
        print("  so an unpinned install eventually lands above it and helm refuses the chart.")
    else:
        print(f"rke2_version {args.rke2}  ->  Kubernetes {kube[0]}.{kube[1]}.{kube[2]}")

    if args.rancher and args.rancher in by_version:
        constraint = by_version[args.rancher]
        print(f"rancher {args.rancher} chart requires kubeVersion {constraint or '(none declared)'}")
        if kube is not None and constraint:
            verdict = satisfies(kube, constraint)
            if verdict is True:
                print(f"{GREEN}OK - the pinned RKE2 version satisfies the Rancher chart{OFF}")
            elif verdict is False:
                print(f"{RED}MISMATCH - helm install rancher will refuse this chart{OFF}")
                workable = [
                    version for version, kv in charts
                    if kv and satisfies(kube, kv) is True
                ]
                if workable:
                    print(f"  Rancher versions that accept Kubernetes {kube[0]}.{kube[1]}: "
                          + ", ".join(workable[:5]))
                print("  Or lower rke2_version to stay under the ceiling.")
            else:
                print(f"{YELLOW}could not interpret the constraint - check it by hand{OFF}")
    elif args.rancher:
        print(f"{YELLOW}rancher {args.rancher} is not in the stable chart index{OFF}")
        print(f"  latest published stable chart: {latest}")
    else:
        print(f"latest published Rancher stable chart: {latest} "
              f"(kubeVersion {by_version.get(latest, '?')})")

    if args.cert_manager:
        print(f"cert_manager_version {args.cert_manager}")
        print("  cert-manager supports a rolling window of Kubernetes releases and")
        print("  publishes no machine-readable constraint - confirm the window at")
        print("  https://cert-manager.io/docs/releases/")
    return 0


if __name__ == "__main__":
    sys.exit(main())

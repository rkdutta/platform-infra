#!/usr/bin/env python3
"""Every apps/**/*application.yaml is a valid Argo CD Application manifest
whose spec.project resolves to a real AppProject file in bootstrap/projects/.
Catches: broken YAML, a typo'd project name (the Application would just
silently never sync), and a project file whose internal metadata.name drifted
from its filename."""
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
APPS = ROOT / "apps"
PROJECTS = ROOT / "bootstrap" / "projects"

errors = []

project_names = set()
for f in PROJECTS.glob("*.yaml"):
    doc = yaml.safe_load(f.read_text())
    name = doc.get("metadata", {}).get("name")
    if name != f.stem:
        errors.append(f"{f}: metadata.name '{name}' != filename '{f.stem}'")
    project_names.add(f.stem)

app_files = sorted(APPS.glob("**/*application.yaml"))
if not app_files:
    errors.append(f"no application.yaml files found under {APPS}")

for f in app_files:
    try:
        doc = yaml.safe_load(f.read_text())
    except yaml.YAMLError as e:
        errors.append(f"{f}: invalid YAML: {e}")
        continue
    if not isinstance(doc, dict):
        errors.append(f"{f}: not a single YAML mapping document")
        continue
    if doc.get("kind") != "Application" or not str(doc.get("apiVersion", "")).startswith("argoproj.io/"):
        errors.append(f"{f}: not an argoproj.io Application (kind={doc.get('kind')})")
        continue
    project = doc.get("spec", {}).get("project")
    if project not in project_names:
        errors.append(f"{f}: spec.project '{project}' has no matching bootstrap/projects/{project}.yaml")

if errors:
    print(f"{len(errors)} problem(s):")
    for e in errors:
        print(f"  {e}")
    sys.exit(1)

print(f"{len(app_files)} Application manifests OK, {len(project_names)} AppProjects OK")

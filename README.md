# K3s JSON schemas

JSON schemas for every object of K3s.

## Usage

This repository contains a `schemas/*` branch for each version of K3s, each of which has multiple flavors:

 * `local`: schemas with relative references.
 * `local-strict`: schemas with relative references that prohibit additional properties.
 * `standalone`: de-referenced schemas.
 * `standalone-strict`: de-referenced schemas that prohibit additional properties.

Just use your favorite JSON schema validation tool for your Kubernetes definitions, such as Red Hat's [YAML Language Support extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml) for VSCode.

```yaml
---
# yaml-language-server: $schema=https://github.com/hectorm/k3s-json-schemas/raw/schemas/<version>/<flavor>/deployment-apps-v1.json
apiVersion: "apps/v1"
kind: "Deployment"
# [...]
---
# yaml-language-server: $schema=https://github.com/hectorm/k3s-json-schemas/raw/schemas/<version>/<flavor>/service-v1.json
apiVersion: "v1"
kind: "Service"
# [...]
```

## Prior-art

This project is inspired by [instrumenta/kubernetes-json-schema](https://github.com/instrumenta/kubernetes-json-schema) and uses its own fork of [openapi2jsonschema](https://github.com/hectorm/openapi2jsonschema) with some improvements.

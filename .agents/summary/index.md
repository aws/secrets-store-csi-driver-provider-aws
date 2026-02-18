# Documentation Index — secrets-store-csi-driver-provider-aws

> **For AI Assistants**: This file is the primary entry point for understanding this codebase. Read this file first to determine which detailed documentation files to consult for specific questions. Each entry below describes the file's purpose and the types of questions it can answer.

## Project Summary

AWS Secrets Store CSI Driver Provider (ASCP) — a Go gRPC server plugin that mounts AWS Secrets Manager and SSM Parameter Store values as files in Kubernetes pods. Version 2.2.1, deployed as a DaemonSet via Helm or kubectl.

## Documentation Files

### [codebase_info.md](codebase_info.md)
**What it covers**: Project metadata, tech stack versions, directory structure, code metrics.
**Consult when**: You need to know the Go version, dependency versions, file locations, or overall project size. Good starting point for orientation.

### [architecture.md](architecture.md)
**What it covers**: High-level system design, request flow diagrams, design patterns (factory, strategy, failover), deployment topology.
**Consult when**: You need to understand how components connect, the gRPC communication model, the mount request lifecycle, or why the code is structured the way it is.

### [components.md](components.md)
**What it covers**: Detailed breakdown of each Go package — purpose, key types, key functions, and responsibilities.
**Consult when**: You need to understand what a specific package does, what functions are available, or where to add new functionality.

### [interfaces.md](interfaces.md)
**What it covers**: All Go interfaces (`ConfigProvider`, `SecretProvider`, `SecretsManagerGetDescriber`, `ParameterStoreGetter`), the gRPC interface, and Kubernetes API usage.
**Consult when**: You need to implement a new provider, understand the contract between components, write mocks for testing, or extend the authentication system.

### [data_models.md](data_models.md)
**What it covers**: All struct definitions (`SecretDescriptor`, `SecretValue`, `JMESPathEntry`, `FailoverObjectEntry`, `Auth`, `CSIDriverProviderServer`), their fields, methods, and validation rules.
**Consult when**: You need to understand the data flowing through the system, YAML parsing rules, validation constraints, or how failover objects work.

### [workflows.md](workflows.md)
**What it covers**: Step-by-step flowcharts for all major processes — mount requests, authentication (IRSA + Pod Identity), secret fetching (SM + SSM), file writing, CI/CD, and integration testing.
**Consult when**: You need to trace a specific code path, debug a failure, understand the order of operations, or modify a workflow.

### [dependencies.md](dependencies.md)
**What it covers**: All direct Go dependencies with versions and purposes, Helm chart dependencies, build tool requirements, and the container image layer structure.
**Consult when**: You need to update a dependency, understand why a package is imported, set up a build environment, or troubleshoot dependency issues.

## Cross-Reference Guide

| Question Type | Primary File | Supporting Files |
|--------------|-------------|-----------------|
| "How does mounting work?" | workflows.md | architecture.md, components.md |
| "How does auth work?" | workflows.md | interfaces.md, components.md |
| "What's the failover logic?" | architecture.md | data_models.md, workflows.md |
| "How do I add a new secret provider?" | interfaces.md | components.md, architecture.md |
| "What does SecretDescriptor validate?" | data_models.md | components.md |
| "How do I run tests?" | workflows.md | dependencies.md, codebase_info.md |
| "What AWS APIs are called?" | dependencies.md | interfaces.md, components.md |
| "Where is file X?" | codebase_info.md | components.md |
| "How is the container built?" | dependencies.md | workflows.md |
| "What Helm values are available?" | components.md | dependencies.md |

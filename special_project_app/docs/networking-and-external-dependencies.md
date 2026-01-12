# Networking & External Dependencies

## 1. Overview

This document covers how traffic flows through OpenShift networking for the Special Payment Project, and how the application depends on internal gateway and DNS configuration.

## 2. Ingress / Routing

### 2.1 User-facing route

- Host: `special-payment.<apps-domain>`
- Back-end: `checkout-frontend` Service in `special-payment-project`
- Protocols: HTTP/HTTPS (TLS termination handled at the route/ingress level)

In many setups:

- `/api` path is forwarded to the `checkout-api` Service.

## 3. Service Topology

### 3.1 Application namespace: special-payment-project

- `checkout-frontend` – ClusterIP Service, port 8080
- `checkout-api` – ClusterIP Service, port 8000
- `card-gateway-dns` – Service of type ExternalName

### 3.2 Provider namespace: payments-provider-sim

- `card-gateway-sandbox` – ClusterIP Service, port 5678
  - Receives traffic only from within the cluster.

## 4. DNS & ExternalName Details

### 4.1 card-gateway-dns

- Location: `special-payment-project` namespace
- Service type: ExternalName

Purpose:

- Provide a stable hostname (`card-gateway-dns`) within the application namespace.
- Allow the actual implementation and namespace of the payment gateway to evolve without changing `checkout-api` code.

### 4.2 Canonical target FQDN

The `spec.externalName` of `card-gateway-dns` should be:

`card-gateway-sandbox.payments-provider-sim.svc.cluster.local`

This is the fully qualified internal DNS name of the gateway service in the provider namespace.

### 4.3 Behaviour

When `checkout-api` calls:

`http://card-gateway-dns:5678`

Cluster DNS resolves `card-gateway-dns` to the configured `externalName`.

Traffic is routed to the gateway service in `payments-provider-sim`.

If DNS resolution fails or the target host does not exist, `checkout-api` will see connection or resolution errors and typically return 5xx to the caller.

## 5. Network Policies (if applicable)

Environments may define `NetworkPolicy` objects that:

- Allow traffic from `special-payment-project` to `payments-provider-sim` on port 5678.
- Restrict traffic from other namespaces.

If NetworkPolicies are configured incorrectly, `checkout-api` may fail to reach `card-gateway-sandbox` even when DNS is correct.

## 6. External Dependencies

In this reference setup, the payment gateway is simulated inside the cluster. In real deployments, the gateway could be:

- An internal payments platform, or
- An external SaaS provider.

The same pattern (internal DNS alias + configuration in the API layer) can be used for those scenarios.

## 7. Things to Watch For

Based on experience with similar architectures, common networking/DNS issues include:

- `ExternalName` pointing at a non-existent or misspelled FQDN.
- Gateway Service renamed or moved to a different namespace without updating the alias.
- NetworkPolicies blocking traffic between `special-payment-project` and `payments-provider-sim`.
- Cluster DNS issues causing intermittent inability to resolve internal hostnames.

If the frontend reports persistent HTTP 5xx errors during checkout while pods appear healthy, useful first checks are:

- `checkout-api` configuration for the gateway URL.
- The `card-gateway-dns` Service definition (type and `externalName`).
- The existence and status of the gateway Service/FQDN in the provider namespace.



# Overview & Context

## 1. Purpose

The Special Payment Project is a small web application that simulates a checkout and card payment flow.

It is used internally to validate patterns around:

- Microservice-based checkout flows
- Integration with payment gateways
- Basic observability and alerting
- Operational practices on OpenShift

The application is not customer-facing in production, but behaves like a simplified e-commerce checkout.

## 2. High-Level Functionality

- Web-based checkout front end
- Backend API for handling checkout requests
- Integration with an internal payment gateway abstraction, which in turn talks to a simulated “card processor”
- Basic success/failure handling and error reporting to the user

From a user’s point of view:

1. They open the checkout page.
2. Enter dummy payment details.
3. Click Pay.
4. Either see a success message or an error if something in the path fails.

## 3. Environments

Currently deployed environments:

- DEV – main environment used for experimentation and testing.
- LAB / DEMO – internal environment used during enablement sessions (optional).

All environments share the same basic architecture, with differences in:

- Cluster size and capacity
- Routing configuration (`<apps-domain>`)
- Monitoring and alerting thresholds

## 4. Ownership

Application owner: Internal app / platform engineering team.

Namespace ownership:

- `special-payment-project` – app team
- `payments-provider-sim` – platform / “provider” team

Operational responsibilities:

App team:

- Behaviour of the frontend and backend
- Application configuration (e.g. environment variables)

Platform team:

- Cluster health, networking, DNS, and gateway-related services
- Access control and routing

## 5. Technology Stack (Summary)

- Platform: Red Hat OpenShift (Kubernetes)
- Frontend: Containerised web UI (JavaScript SPA served by a simple HTTP server)
- Backend: FastAPI (Python)
- Gateway / provider simulation: Lightweight HTTP service acting as a fake card gateway

Networking:

- OpenShift Routes / Ingress
- ClusterIP Services
- One ExternalName Service used as a DNS alias to the gateway

Monitoring: Prometheus + Alertmanager  
Logging: Cluster logging stack (varies by environment)





# ansible-aiops-with-llama-stack
AIOps project for ticket enrichment and auto-remediation using llama stack to pull together agentic components.


## Dependancies
- AAP 2.5 or 2.6
- Servicenow Developer instance (ensure time is set to Europe/London)
- Openshift 3.20 with Openshift AI 3.0 installed.

## Pre-Tasks
- Log into openshift cluster as admin

## Instructions

1. Copy .env.example and populate .env with actual variables.
Note: VECTOR_DB_ID and OCP_API_TOKEN are populated by the scripts you will run below.
```sh
cp .env.example .env
```

2. Deploy Special Project using script
```sh
./llama-stack/scripts/oc-deploy.sh
```

3. Deploy OCP MCP server.
Creates the llama-stack-demo project if it does not already exist.
Creates the roles and rolebindings needed to make this mcp server project level scoped to the special-payment-project
```sh
./llama-stack/scripts/oc-deploy.sh
```

4. Deploy Llama Stack
RAG in this case does not use external VectorDB
Deploys llama stack with a brand new Vector Store.
```sh
./llama-stack/scripts/oc-deploy.sh
```
Run the below to delete current vector store and create a new one.
```sh
./llama-stack/scripts/oc-deploy.sh --reset-vector-db
```

5. Run the Confluence ingestor Job
This is a one time job that will run to ingest confluence documentation from a given confluence space.
```sh
./confluence_ingestor/oc_binary_build_deploy.sh
```

6. Deploy k8s_diagnostics_agent
Remember at this pointwe have not ingested any docs so the example questions will not work properly.
```sh
./k8s_diagnostics_agent/scripts/oc-deploy.sh
```

7. Configure AAP
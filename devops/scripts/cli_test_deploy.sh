#!/bin/bash

# This script tests deploying a workspace via the CLI

set -o pipefail
# set -o xtrace

echo "======================================"
echo "Deploy workspace"
echo "======================================"

date_string=$(date +"%F %T")
operation_output=$(cat << EOF | tre workspaces new --definition-file - --output json
{
  "templateName": "tre-workspace-base",
  "properties": {
    "display_name": "Test workspace $date_string",
    "description": "CLI automated workspace test",
    "client_id":"auto_create",
    "address_space_size": "small",
    "app_service_plan_sku": "${WORKSPACE_APP_SERVICE_PLAN_SKU:-P1v2}"
  }
}
EOF
)
# shellcheck disable=SC2181
if [[ $? != 0 ]]; then
  echo "Error: $operation_output"
  exit 1
fi
operation_status=$(echo "$operation_output" | jq -r .operation.status)
echo "$operation_status"
if [[ $operation_status == "deployed" ]]; then
    workspace_id=$(echo "$operation_output" | jq -r .operation.resourceId)
    echo "Created workspace $workspace_id"
else
  echo "Failed: $operation_output"
  exit 1
fi

echo "Checking AAD token for workspace:"
token_valid=false
for i in {1..30}; do
  if [[ $(tre get-token --workspace "$workspace_id" --decode -o json --query "contains(not_null(roles, ['']), 'WorkspaceOwner')") == "true" ]]; then
    token_valid=true
    echo "AAD Token contains WorkspaceOwner role for workspace ✅"
    break
  fi
  echo "Waiting for Azure AD to show user as WorkspaceOwner ($i)... 🕛"
  sleep 5s
done
if [[ "$token_valid" != "true" ]]; then
  echo "WorkspaceOwner role not in AAD Token. Giving up!"
  exit 1
fi


echo
echo "======================================"
echo "Deploy workspace service (guacamole)"
echo "======================================"

operation_output=$(cat << EOF | tre workspace "$workspace_id" workspace-services new --definition-file - --output json
{
    "templateName": "tre-service-guacamole",
    "properties": {
        "display_name": "Guac",
        "description": "Guacaomle workspace service",
        "is_exposed_externally": true,
        "guac_disable_copy": true,
        "guac_disable_paste": false
    }
}
EOF
)
# shellcheck disable=SC2181
if [[ $? != 0 ]]; then
  echo "Error: $operation_output"
  exit 1
fi
operation_status=$(echo "$operation_output" | jq -r .operation.status)
echo "$operation_status"
if [[ $operation_status == "deployed" ]]; then
    guacamole_service_id=$(echo "$operation_output" | jq -r .operation.resourceId)
    echo "Created guacamole workspace service $guacamole_service_id"
else
  echo "Failed: $operation_output"
  exit 1
fi


# TODO: deploy user-resource

echo
echo "======================================"
echo "Create import airlock request"
echo "======================================"

# Create the airlock request - change the justification as appropriate
request=$(tre workspace "$workspace_id" airlock-requests new --type import --title "Ant" --justification "It's import-ant" --output json)
request_id=$(echo "$request" | jq -r .airlockRequest.id)
echo "Airlock request ID: $request"

# Get the storage upload URL
upload_url=$(tre workspace $"$workspace_id" airlock-request "$request_id" get-url --query containerUrl --output raw)

# Create dummy content to upload
mkdir cli-test-temp -p
echo '*' > cli-test-temp/.gitignore
echo 'What do you call a happy ant? Exuber-ant' > cli-test-temp/ant.txt

# Use the az CLI to upload ant.txt
az storage blob upload-batch --source . --pattern cli-test-temp/ant.txt --destination "$upload_url"

# Submit the request for review
tre workspace "$workspace_id" airlock-request "$request_id" submit

# wait for the airlock to be in the submitted state
status=""
for _ in {1..60} # wait for 60 * 5s = 300s = 5 minutes
do
  status=$(tre workspace "$workspace_id" airlock-request "$request_id" show --output raw --query airlockRequest.status)
  if [[ "$status" == "submitted" ]]; then
    break
  fi
  echo "Waiting for airlock request 'submitted' state..."
  sleep 5s
done
if [[ "$status" != "submitted" ]]; then
  echo "Failed to reach 'submitted' status - last status was '$status'"
  exit 1
fi

# Approve the airlock request
tre workspace "$workspace_id" airlock-request "$request_id" review --approve --reason "Looks good to me"

# TODO - wait for final state


echo
echo "======================================"
echo "Deleting workspace service (guacamole)"
echo "======================================"

tre workspace "$workspace_id" workspace-service "$guacamole_service_id" delete --ensure-disabled --yes
# shellcheck disable=SC2181
if [[ $? != 0 ]]; then
  echo "Error: $operation_output"
  exit 1
fi


echo
echo "======================================"
echo "Deleting workspace"
echo "======================================"

tre workspace "$workspace_id" delete --ensure-disabled --yes
# shellcheck disable=SC2181
if [[ $? != 0 ]]; then
  echo "Error: $operation_output"
  exit 1
fi

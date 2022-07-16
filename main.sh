#!/bin/bash

set -eo pipefail

if [ ! -z "$MAESTRO_BRANCH_OVERRIDE" ]; then
    BRANCH=$MAESTRO_BRANCH_OVERRIDE
else
    BRANCH=$CODEBUILD_SOURCE_VERSION
fi

echo "AWS CLI Version: $(aws --version)"
echo "Buildpack CLI Version: $(pack --version)"

AWS_ACCOUNT_ID=$(cut -d':' -f5 <<<$CODEBUILD_BUILD_ARN)
if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG=${CODEBUILD_SOURCE_REPO_URL#*://*/}
    REPO_SLUG=${REPO_SLUG,,}
fi
REPO_SLUG=${REPO_SLUG%.git}
REPO_SLUG=${REPO_SLUG/\//-}
REPO_SLUG=${REPO_SLUG/\./-}
COMMIT_SHORT=$(head -c 8 <<<$CODEBUILD_RESOLVED_SOURCE_VERSION)
IMAGE_NAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_SLUG-$BRANCH:$COMMIT_SHORT

main_application_secrets=$(aws secretsmanager get-secret-value --secret-id $BRANCH/$REPO_SLUG)
main_application_environment_variables=$(jq -r '.SecretString | fromjson | to_entries | .[] | .key + "=" + (.value|tostring)' <<<$main_application_secrets)
main_export_regex="^([A-Z0-9_])+[=]+(.*)"
for ENV_LINE in $main_application_environment_variables; do
    if [[ $ENV_LINE =~ ${main_export_regex} ]]; then
        export $ENV_LINE
        echo $ENV_LINE >> .env
    else
        echo "   SKIPPED: >> ${ENV_LINE}"
        main_export_errors=true
    fi
done

if [ ! -z "$main_export_errors" ]; then
    echo "    WARNING: The above noted environment variables were skipped from the export, as they were not identified as a valid value or by a flag."
fi

if [ -z "$MAESTRO_SKIP_BUILD" ]; then
    build.sh --image-name $IMAGE_NAME
    if [ ! -z "$MAESTRO_ONLY_BUILD" ]; then
        echo "----> Build completed. Skipping further steps..."
        exit 0
    fi
else
    echo "----> Skipping build and running further steps..."
fi

if [ -z "$ECS_CLUSTER_ID" ]; then
  export ECS_CLUSTER_ID=$REPO_SLUG-$BRANCH
fi

main_processes=$(pack inspect $IMAGE_NAME | sed '0,/^Processes:$/d' | tail -n +2 | cut -d' ' -f3)
main_processes=${main_processes%$'\n'*}
main_processes=${main_processes%$'\n'}
# refactor line break below
main_processes="$main_processes
launcher"
main_services=$(aws ecs list-services --cluster $ECS_CLUSTER_ID)
while IFS= read -r line; do
    main_create_service=$(jq ".serviceArns[] | select(endswith(\"$REPO_SLUG-$BRANCH-$line\"))" <<<$main_services)
    release.sh --image-name $IMAGE_NAME \
    --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH \
    --cluster-id $ECS_CLUSTER_ID \
    
    provision.sh --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH

    deploy.sh --process-type $line \
    --service-name $REPO_SLUG-$BRANCH-$line \
    --security-group-name $REPO_SLUG-$line-$BRANCH-app \
    --cluster-id $ECS_CLUSTER_ID \
    --repository-slug $REPO_SLUG \
    --account-id $AWS_ACCOUNT_ID \
    $( [ -z "$main_create_service" ] && echo "--create-service")
done <<< "$main_processes"
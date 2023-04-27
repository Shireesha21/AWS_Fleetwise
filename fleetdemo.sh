#Shell Scripting
#!/bin/bash
set -euo pipefail

ENDPOINT_URL=""
ENDPOINT_URL_OPTION=""
REGION="us-east-1"
TIMESTAMP=`date +%s`
ACCOUNT_ID=`aws sts get-caller-identity --query "Account" --output text`
DEFAULT_VEHICLE_NAME="samplevehicle"
VEHICLE_NAME=""
TIMESTREAM_DATABASE_NAME="TSDB-${TIMESTAMP}"
TIMESTREAM_TABLE_NAME="VDT"
CAMPAIGN_FILE_NAME=""
DEFAULT_CAMPAIGN_FILE_NAME="campaign-vehicle-event.json"
DBC_FILE_NAME=""
DEFAULT_DBC_FILE_NAME="vehicledatasignal.dbc"
CLEAN_UP=false
FLEET_SIZE=1
BATCH_SIZE=$((`nproc`*4))
HEALTH_CHECK_RETRIES=400 
MAX_ATTEMPTS_ON_REGISTRATION_FAILURE=4
FORCE_REGISTRATION=false

parse_args() {
    while [ "$#" -gt 0 ]; do
        case $1 in
        --vehicle-name)
            VEHICLE_NAME=$2
            shift
            ;;
        --fleet-size)
            FLEET_SIZE=$2
            shift
            ;;
        --clean-up)
            CLEAN_UP=true
            ;;
        --campaign-file)
            CAMPAIGN_FILE=$2
            shift
            ;;
        --dbc-file)
            DBC_FILE_NAME=$2
            shift
            ;;
        --endpoint-url)
            ENDPOINT_URL=$2
            shift
            ;;
        --region)
            REGION=$2
            shift
            ;;
        --force-registration)
            FORCE_REGISTRATION=true
            ;;
        --help)
            echo "Usage: $0 [OPTION]"
            echo " Vehicle Name:        --vehicle-name <NAME>   Vehicle name"
            echo " Fleet Size:          --fleet-size <SIZE>     Size of fleet, default: ${FLEET_SIZE}. When greater than 1,"
            echo "                              the instance number will be appended to each"
            echo "                              Vehicle name after a '-', e.g. ${DEFAULT_VEHICLE_NAME}-42"
            echo " Campaign File:       --campaign-file <FILE>  Campaign JSON file, default: ${DEFAULT_CAMPAIGN_FILE_NAME}"
            echo " DBC File:            --dbc-file <FILE>       DBC file, default: ${DEFAULT_DBC_FILE_NAME}"
            echo " CLEAN UP:            --clean-up              Delete created resources"
            echo " ENDPOINT_URL:        --endpoint-url <URL>    The endpoint URL used for AWS CLI calls"
            echo " REGION:              --region <REGION>       The region used for AWS CLI calls, default: ${REGION}"
            echo " FORCE REGISTRATION:  --force-registration    Force account registration"
            exit 0
            ;;
        esac
        shift
    done
    if [ "${ENDPOINT_URL}" != "" ]; then
        ENDPOINT_URL_OPTION="--endpoint-url ${ENDPOINT_URL}"
    fi
    if ((FLEET_SIZE==0)); then
        echo "Error: Fleet size must be greater than zero" >&2
        exit -1
    fi
}

parse_args "$@"

if [ "${VEHICLE_NAME}" == "" ]; then
    echo -n "This from Line 92: Here Try Entering the Vehicle name [${DEFAULT_VEHICLE_NAME}]: "
    read VEHICLE_NAME
    if [ "${VEHICLE_NAME}" == "" ]; then
        VEHICLE_NAME=${DEFAULT_VEHICLE_NAME}
    fi
fi

if [ "${DBC_FILE_NAME}" != "" ] && [ "${CAMPAIGN_FILE_NAME}" == "" ]; then
    echo -n "This from Line 100: Entering campaign file name: "
    read CAMPAIGN_FILE_NAME
    if [ "${CAMPAIGN_FILE_NAME}" == "" ]; then
        echo "This from Line 103: Error:  campaign file name for custom DBC file is not provided" >&2
        exit -1
    fi
fi

if [ "${CAMPAIGN_FILE_NAME}" == "" ]; then
    CAMPAIGN_FILE_NAME=${DEFAULT_CAMPAIGN_FILE_NAME}
fi

NAME="${VEHICLE_NAME}-${TIMESTAMP}"

echo -n "This from Line 114: Date: "
date +%Y-%m-%dT%H:%M:%S%z
echo "This from Line 116: Timestamp: ${TIMESTAMP}"
echo "This from Line 117: Vehicle name: ${VEHICLE_NAME}"
echo "This from Line 118: Fleet Size: ${FLEET_SIZE}"

echo "This from Line 121: Checking AWS CLI version"
CLI_VERSION=`aws --version`
echo ${CLI_VERSION}
if echo "${CLI_VERSION}" | grep -q "aws-cli/1."; then
    echo "This from Line 125: Error: Please update AWS CLI to v2.x" >&2
    exit -1
fi

#This for handling errors
error_handler() {
    if [ ${CLEAN_UP} == true ]; then
        ./clean-up.sh \
            --vehicle-name ${VEHICLE_NAME} \
            --fleet-size ${FLEET_SIZE} \
            --timestamp ${TIMESTAMP} \
            ${ENDPOINT_URL_OPTION} \
            --region ${REGION}
    fi
}

#Account Registration 
register_account() {
    echo "This from Line 141: Registering account..."
    aws iotfleetwise register-account \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --timestream-resources "{\"timestreamDatabaseName\":\"${TIMESTREAM_DATABASE_NAME}\", \
            \"timestreamTableName\":\"${TIMESTREAM_TABLE_NAME}\"}" | jq -r .registerAccountStatus
    echo "This from Line 146: waiting for account registration....!!! "
}

#Here we can get the account details
get_account_status() {
    aws iotfleetwise get-register-account-status ${ENDPOINT_URL_OPTION} --region ${REGION}
}

trap error_handler ERR

echo "This from Line 155: Fetching AWS account ID "
echo ${ACCOUNT_ID}

echo "This from Line 158: Fetching account registration status"
if REGISTER_ACCOUNT_STATUS=`get_account_status 2>&1`; then
    ACCOUNT_STATUS=`echo "${REGISTER_ACCOUNT_STATUS}" | jq -r .accountStatus`
elif ! echo ${REGISTER_ACCOUNT_STATUS} | grep -q "ResourceNotFoundException"; then
    echo ${REGISTER_ACCOUNT_STATUS} >&2
    exit -1
else
    ACCOUNT_STATUS="NOT_REGISTERED"
fi

echo ${ACCOUNT_STATUS}
if ${FORCE_REGISTRATION}; then
    echo "This from Line 169: Forcing registration"
    ACCOUNT_STATUS="FORCE_REGISTRATION"
fi

# To know the registration status
if [ "${ACCOUNT_STATUS}" == "REGISTRATION_SUCCESS" ]; then
    echo "This from Line 173: Account is already registered"
    TIMESTREAM_DATABASE_NAME=`echo "${REGISTER_ACCOUNT_STATUS}" | jq -r .timestreamRegistrationResponse.timestreamDatabaseName`
    echo "This from Line 176: Checking if Timestream database exists..."
    if TIMESTREAM_INFO=`aws timestream-write describe-database \
        --region ${REGION} --database-name ${TIMESTREAM_DATABASE_NAME} 2>&1`; then
        echo ${TIMESTREAM_INFO} | jq -r .Database.Arn
    elif ! echo ${TIMESTREAM_INFO} | grep -q "ResourceNotFoundException"; then
        echo ${TIMESTREAM_INFO} >&2
        exit -1
    else
        echo "This from Line 183: Error: Timestream database no longer exists. Try running script again with option --force-registration" >&2
        exit -1
    fi
elif [ "${ACCOUNT_STATUS}" == "REGISTRATION_PENDING" ]; then
    echo "This from Line 187: Account registration pending: ${ACCOUNT_STATUS} "
else
    echo "This from Line 189: Creating Timestream database"
    aws timestream-write create-database \
        --region ${REGION} \
        --database-name ${TIMESTREAM_DATABASE_NAME} | jq -r .Database.Arn

    echo "This from Line 194: Creating Timestream table"
    aws timestream-write create-table \
        --region ${REGION} \
        --database-name ${TIMESTREAM_DATABASE_NAME} \
        --table-name ${TIMESTREAM_TABLE_NAME} \
        --retention-properties "{\"MemoryStoreRetentionPeriodInHours\":2, \
            \"MagneticStoreRetentionPeriodInDays\":2}" | jq -r .Table.Arn

    register_account
fi

REGISTRATION_ATTEMPTS=0
while [ "${ACCOUNT_STATUS}" != "REGISTRATION_SUCCESS" ]; do
    sleep 5
    REGISTER_ACCOUNT_STATUS=`get_account_status`
    ACCOUNT_STATUS=`echo "${REGISTER_ACCOUNT_STATUS}" | jq -r .accountStatus`
    if [ "${ACCOUNT_STATUS}" == "REGISTRATION_FAILURE" ]; then
        echo "This from Line 211: Error: Registration failed" >&2
        ((REGISTRATION_ATTEMPTS+=1))
        if ((REGISTRATION_ATTEMPTS >= MAX_ATTEMPTS_ON_REGISTRATION_FAILURE)); then
            echo "This from Line 214: ${REGISTER_ACCOUNT_STATUS}" >&2
            echo "This from Line 215: All ${MAX_ATTEMPTS_ON_REGISTRATION_FAILURE} registration attempts failed" >&2
            exit -1
        else
            register_account
        fi
    fi
done
TIMESTREAM_DATABASE_NAME=`echo "${REGISTER_ACCOUNT_STATUS}" | jq -r .timestreamRegistrationResponse.timestreamDatabaseName`
TIMESTREAM_TABLE_NAME=`echo "${REGISTER_ACCOUNT_STATUS}" | jq -r .timestreamRegistrationResponse.timestreamTableName`


if ((FLEET_SIZE==1)); then
    echo "This from Line 226: Deleting vehicle ${VEHICLE_NAME} if it already exists..."
    aws iotfleetwise delete-vehicle \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --vehicle-name "${VEHICLE_NAME}"
else
    echo "This from Line 231: Deleting vehicle ${VEHICLE_NAME}-0..$((FLEET_SIZE-1)) if it already exists"
    for ((i=0; i<${FLEET_SIZE}; i+=${BATCH_SIZE})); do
        for ((j=0; j<${BATCH_SIZE} && i+j<${FLEET_SIZE}; j++)); do
            { \
                aws iotfleetwise delete-vehicle \
                    ${ENDPOINT_URL_OPTION} --region ${REGION} \
                    --vehicle-name "${VEHICLE_NAME}-$((i+j))" \
            2>&3 &} 3>&2 2>/dev/null
        done
        wait
    done
fi


VEHICLE_NODE=`cat vehicle-node.json`
OBD_NODES=`cat obd-nodes.json`
if [ "${DBC_FILE_NAME}" == "" ]; then
    DBC_NODES=`python3 dbc-to-nodes.py ${DEFAULT_DBC_FILE_NAME}`
else
    DBC_NODES=`python3 dbc-to-nodes.py ${DBC_FILE_NAME}`
fi

echo "This from Line 252: Checking for existing signal catalog..."
SIGNAL_CATALOG_LIST=`aws iotfleetwise list-signal-catalogs \
    ${ENDPOINT_URL_OPTION} --region ${REGION}`
SIGNAL_CATALOG_COUNT=`echo ${SIGNAL_CATALOG_LIST} | jq '.summaries|length'`
if [ ${SIGNAL_CATALOG_COUNT} == 0 ]; then
    echo "This from Line 258: Creating signal catalog with Vehicle node..."
    SIGNAL_CATALOG_ARN=`aws iotfleetwise create-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-signal-catalog \
        --nodes "${VEHICLE_NODE}" | jq -r .arn`
    echo ${SIGNAL_CATALOG_ARN}

   
    echo "Adding OBD signals to signal catalog..."
    aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-signal-catalog \
        --description "OBD signals" \
        --nodes-to-add "${OBD_NODES}" | jq -r .arn
    

    echo "This from Line 276: Adding DBC signals to signal catalog..."
    aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-signal-catalog \
        --description "DBC signals" \
        --nodes-to-add "${DBC_NODES}" | jq -r .arn

    echo "This from Line 283: Add an attribute to signal catalog..."
    aws iotfleetwise update-signal-catalog \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-signal-catalog \
        --description "DBC Attributes" \
        --nodes-to-add '[{
            "attribute": {
                "dataType": "STRING",
                "description": "Color",
                "fullyQualifiedName": "Vehicle.Color",
                "defaultValue":"Red"
            }}
        ]' | jq -r .arn
else
    SIGNAL_CATALOG_NAME=`echo ${SIGNAL_CATALOG_LIST} | jq -r .summaries[0].name`
    SIGNAL_CATALOG_ARN=`echo ${SIGNAL_CATALOG_LIST} | jq -r .summaries[0].arn`
    echo ${SIGNAL_CATALOG_ARN}

    echo "This from Line 301: Updating Vehicle node in signal catalog"
    if UPDATE_SIGNAL_CATALOG_STATUS=`aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${SIGNAL_CATALOG_NAME} \
        --description "Vehicle node" \
        --nodes-to-update "${VEHICLE_NODE}" 2>&1`; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} | jq -r .arn
    elif ! echo ${UPDATE_SIGNAL_CATALOG_STATUS} | grep -q "InvalidSignalsException"; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} >&2
        exit -1
    else
        echo "This from Line 312: Node exists and is in use, continuing"
    fi

    echo "Updating OBD signals in signal catalog..."
    if UPDATE_SIGNAL_CATALOG_STATUS=`aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${SIGNAL_CATALOG_NAME} \
        --description "OBD signals" \
        --nodes-to-update "${OBD_NODES}" 2>&1`; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} | jq -r .arn
    elif ! echo ${UPDATE_SIGNAL_CATALOG_STATUS} | grep -q "InvalidSignalsException"; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} >&2
        exit -1
    else
        echo "Signals exist and are in use, continuing"
    fi

    echo "This from Line 332: Updating DBC signals in signal catalog"
    if UPDATE_SIGNAL_CATALOG_STATUS=`aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${SIGNAL_CATALOG_NAME} \
        --description "DBC signals" \
        --nodes-to-update "${DBC_NODES}" 2>&1`; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} | jq -r .arn
    elif ! echo ${UPDATE_SIGNAL_CATALOG_STATUS} | grep -q "InvalidSignalsException"; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} >&2
        exit -1
    else
        echo "This from Line 343: Signals exist and are in use, continuing"
    fi

    echo "This from Line 346: Updating color attribute"
    if UPDATE_SIGNAL_CATALOG_STATUS=`aws iotfleetwise update-signal-catalog \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${SIGNAL_CATALOG_NAME} \
        --description "DBC Attributes" \
        --nodes-to-add '[{
            "attribute": {
                "dataType": "STRING",
                "description": "Color",
                "fullyQualifiedName": "Vehicle.Color",
                "defaultValue":"Red"
            }}
        ]' 2>&1`; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} | jq -r .arn
    elif ! echo ${UPDATE_SIGNAL_CATALOG_STATUS} | grep -q "InvalidSignalsException"; then
        echo ${UPDATE_SIGNAL_CATALOG_STATUS} >&2
        exit -1
    else
        echo "This from Line 364: Signals exist and are in use, continuing"
    fi
fi

echo "This from Line 368: Creating model manifest..."
# Make a list of all node names:

NODE_LIST=`( echo ${DBC_NODES} | jq -r .[].sensor.fullyQualifiedName | grep Vehicle\\. ; \
             echo ${OBD_NODES} | jq -r .[].sensor.fullyQualifiedName | grep Vehicle\\. ) | jq -Rn [inputs]`
aws iotfleetwise create-model-manifest \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-model-manifest \
    --signal-catalog-arn ${SIGNAL_CATALOG_ARN} \
    --nodes "${NODE_LIST}" | jq -r .arn

echo "Updating attribute in model manifest..."
MODEL_MANIFEST_ARN=`aws iotfleetwise update-model-manifest \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-model-manifest \
    --nodes-to-add 'Vehicle.Color' | jq -r .arn`
echo ${MODEL_MANIFEST_ARN}

echo "Activating model manifest..."
MODEL_MANIFEST_ARN=`aws iotfleetwise update-model-manifest \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-model-manifest \
    --status ACTIVE | jq -r .arn`
echo ${MODEL_MANIFEST_ARN}

echo "Creating decoder manifest with OBD signals..."
NETWORK_INTERFACES=`cat network-interfaces.json`
OBD_SIGNAL_DECODERS=`cat obd-decoders.json`
DECODER_MANIFEST_ARN=`aws iotfleetwise create-decoder-manifest \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-decoder-manifest \
    --model-manifest-arn ${MODEL_MANIFEST_ARN} \
    --network-interfaces "${NETWORK_INTERFACES}" \
    --signal-decoders "${OBD_SIGNAL_DECODERS}" | jq -r .arn`
echo ${DECODER_MANIFEST_ARN}


echo "This from Line 409: Adding DBC signals to decoder manifest..."
if [ "${DBC_FILE_NAME}" == "" ]; then
    DBC=`cat ${DEFAULT_DBC_FILE_NAME} | base64 -w0`
    # Make map of node name to DBC signal name, i.e. {"Vehicle.SignalName":"SignalName"...}
    NODE_TO_DBC_MAP=`echo ${DBC_NODES} | jq '.[].sensor.fullyQualifiedName//""|match("Vehicle\\\\.\\\\w+\\\\.(.+)")|{(.captures[0].string):.string}'|jq -s add`
    NETWORK_FILE_DEFINITIONS=`echo [] \
        | jq .[0].canDbc.signalsMap="${NODE_TO_DBC_MAP}" \
        | jq .[0].canDbc.networkInterface="\"1\"" \
        | jq .[0].canDbc.canDbcFiles[0]="\"${DBC}\""`
    aws iotfleetwise import-decoder-manifest \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-decoder-manifest \
        --network-file-definitions "${NETWORK_FILE_DEFINITIONS}" | jq -r .arn
else
    SIGNAL_DECODERS=`python3 dbc-to-json.py ${DBC_FILE_NAME}`
    aws iotfleetwise update-decoder-manifest \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-decoder-manifest \
        --signal-decoders-to-add "${SIGNAL_DECODERS}" | jq -r .arn
fi

echo "This from Line 430: Activating decoder manifest"
aws iotfleetwise update-decoder-manifest \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-decoder-manifest \
    --status ACTIVE | jq -r .arn

if ((FLEET_SIZE==1)); then
    echo "This from Line 437: Creating vehicle ${VEHICLE_NAME}"
    aws iotfleetwise create-vehicle \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --decoder-manifest-arn ${DECODER_MANIFEST_ARN} \
        --association-behavior ValidateIotThingExists \
        --model-manifest-arn ${MODEL_MANIFEST_ARN} \
        --attributes '{"Vehicle.Color":"Red"}' \
        --vehicle-name "${VEHICLE_NAME}" | jq -r .arn
else
    echo "This from Line 446: Creating vehicle ${VEHICLE_NAME}-0..$((FLEET_SIZE-1))"
    for ((i=0; i<${FLEET_SIZE}; i+=${BATCH_SIZE})); do
        for ((j=0; j<${BATCH_SIZE} && i+j<${FLEET_SIZE}; j++)); do
            { \
                aws iotfleetwise create-vehicle \
                    ${ENDPOINT_URL_OPTION} --region ${REGION} \
                    --decoder-manifest-arn ${DECODER_MANIFEST_ARN} \
                    --association-behavior ValidateIotThingExists \
                    --model-manifest-arn ${MODEL_MANIFEST_ARN} \
                    --attributes '{"Vehicle.Color":"Red"}' \
                    --vehicle-name "${VEHICLE_NAME}-$((i+j))" >/dev/null \
            2>&3 &} 3>&2 2>/dev/null
        done
        wait
    done
fi

echo "This from Line 463: Creating fleet"
FLEET_ARN=`aws iotfleetwise create-fleet \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --fleet-id ${NAME}-fleet \
    --description "Description is required" \
    --signal-catalog-arn ${SIGNAL_CATALOG_ARN} | jq -r .arn`
echo ${FLEET_ARN}

if ((FLEET_SIZE==1)); then
    echo "This from Line 472: Associating vehicle ${VEHICLE_NAME}"
    aws iotfleetwise associate-vehicle-fleet \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --fleet-id ${NAME}-fleet \
        --vehicle-name "${VEHICLE_NAME}"
else
    echo "This from Line 478: Associating vehicle ${VEHICLE_NAME}-0..$((FLEET_SIZE-1))"
    for ((i=0; i<${FLEET_SIZE}; i+=${BATCH_SIZE})); do
        for ((j=0; j<${BATCH_SIZE} && i+j<${FLEET_SIZE}; j++)); do
            { \
                aws iotfleetwise associate-vehicle-fleet \
                    ${ENDPOINT_URL_OPTION} --region ${REGION} \
                    --fleet-id ${NAME}-fleet \
                    --vehicle-name "${VEHICLE_NAME}-$((i+j))" \
            2>&3 &} 3>&2 2>/dev/null
        done
        wait
    done
fi

echo "This from Line 492: Creating campaign from ${CAMPAIGN_FILE_NAME}"
CAMPAIGN=`cat ${CAMPAIGN_FILE_NAME} \
    | jq .name=\"${NAME}-campaign\" \
    | jq .signalCatalogArn=\"${SIGNAL_CATALOG_ARN}\" \
    | jq .targetArn=\"${FLEET_ARN}\"`
aws iotfleetwise create-campaign \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --cli-input-json "${CAMPAIGN}" | jq -r .arn

echo "This from Line 501: Waiting for campaign to become ready for approval"
while true; do
    sleep 5
    CAMPAIGN_STATUS=`aws iotfleetwise get-campaign \
        ${ENDPOINT_URL_OPTION} --region ${REGION} \
        --name ${NAME}-campaign | jq -r .status`
    if [ "${CAMPAIGN_STATUS}" == "WAITING_FOR_APPROVAL" ]; then
        break
    fi
done

echo "This from Line 512: Approving campaign"
aws iotfleetwise update-campaign \
    ${ENDPOINT_URL_OPTION} --region ${REGION} \
    --name ${NAME}-campaign \
    --action APPROVE | jq -r .arn

# The following two actions(Suspending, Resuming) are only for demo purpose, it won't affect the campaign status
#To check the health of Vehicle
check_vehicle_healthy() {
    for ((k=0; k<${HEALTH_CHECK_RETRIES}; k++)); do
        VEHICLE_STATUS=`aws iotfleetwise get-vehicle-status \
            ${ENDPOINT_URL_OPTION} --region ${REGION} \
            --vehicle-name "$1"`
        for ((l=0; ; l++)); do
            CAMPAIGN_NAME=`echo ${VEHICLE_STATUS} | jq -r .campaigns[${l}].campaignName`
            CAMPAIGN_STATUS=`echo ${VEHICLE_STATUS} | jq -r .campaigns[${l}].status`
            # If the campaign was not found (when the index is out-of-range jq will return 'null')
            if [ "${CAMPAIGN_NAME}" == "null" ]; then
                echo "This from Line 546: Error: Campaign not found in vehicle status for vehicle $1" >&2
                exit -1
            # If the campaign was found \
            elif [ "${CAMPAIGN_NAME}" == "${NAME}-campaign" ]; then
                if [ "${CAMPAIGN_STATUS}" == "HEALTHY" ]; then
                    break 2
                fi
                break
            fi
        done
        sleep 5
    done
    if ((k>=HEALTH_CHECK_RETRIES)); then
        echo "This from Line 559: Error: Health check timeout for vehicle $1" >&2
        exit -1
    fi
}

if ((FLEET_SIZE==1)); then
    echo "This from Line 565: Waiting until status of vehicle ${VEHICLE_NAME} is healthy"
    check_vehicle_healthy "${VEHICLE_NAME}"
else
    echo "This from Line 568: Waiting until status of vehicle ${VEHICLE_NAME}-0..$((FLEET_SIZE-1)) is healthy"
    for ((i=0; i<${FLEET_SIZE}; i+=${BATCH_SIZE})); do
        for ((j=0; j<${BATCH_SIZE} && i+j<${FLEET_SIZE}; j++)); do
            { \
                check_vehicle_healthy "${VEHICLE_NAME}-$((i+j))" \
            2>&3 &} 3>&2 2>/dev/null
        done
        wait
    done
fi

DELAY=60
echo "This from Line 580: Waiting ${DELAY} seconds for data to be collected"
sleep ${DELAY}

echo "The DB Name is ${TIMESTREAM_DATABASE_NAME}"
echo "The DB Table is ${TIMESTREAM_TABLE_NAME}"

echo "This from Line 586: Querying Timestream"
aws timestream-query query \
    --region ${REGION} \
    --query-string "SELECT * FROM \"${TIMESTREAM_DATABASE_NAME}\".\"${TIMESTREAM_TABLE_NAME}\" \
        WHERE vehicleName = '${VEHICLE_NAME}`if ((FLEET_SIZE>1)); then echo "-0"; fi`' \
        AND time between ago(1m) and now() ORDER BY time ASC" \
    > ${NAME}-timestream-result.json

if [ "${DBC_FILE_NAME}" == "" ]; then
    echo "This from Line 595: Converting to HTML..."
    OUTPUT_FILE_HTML="${NAME}.html"
    python3 timestream-to-html.py ${NAME}-timestream-result.json ${OUTPUT_FILE_HTML}

    echo "You can now view the collected data."
    echo `pwd`/${OUTPUT_FILE_HTML}
fi

if [ ${CLEAN_UP} == true ]; then
    ./clean-up.sh \
        --vehicle-name ${VEHICLE_NAME} \
        --fleet-size ${FLEET_SIZE} \
        --timestamp ${TIMESTAMP} \
        ${ENDPOINT_URL_OPTION} \
        --region ${REGION}
fi

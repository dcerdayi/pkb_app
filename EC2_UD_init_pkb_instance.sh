#!/bin/bash
REPO="git@github.com:dcerdayi/pkb_app.git"
TMP_DIR="/tmp_deploy"
GIT_SECRET_S3_LOC="s3://dce-deploy/secrets/aws_github_key"
GIT_SECRET_LOCAL_LOC="${TMP_DIR}/$(basename "$GIT_SECRET_S3_LOC")"
REPO_CLONE_DIR="${TMP_DIR}/repo_clone"
# ========================================================================
# Section: Volume Operations
# ========================================================================
# Specify the volume and filesystem type
VOLUME="/dev/xvdbf"
MOUNT_POINT="/mnt/kb_data"
FILESYSTEM_TYPE="ext4"
VOLUME_NAME_TAG="kb_volume_001"
VOLUME_SIZE=5  # gb
VOLUME_TYPE="gp3"
IOPS=3000
THROUGHPUT=125

log_message() {
  local MESSAGE="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $MESSAGE"
}

# Check for sudo permissions
if ! sudo -v; then
  echo "This script requires sudo privileges. Exiting."
  exit 1
fi

log_message "Starting script to mount and format volume $VOLUME"

# Get the region and instance ID
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCEID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Check if there is an existing volume with the specified tag
EXISTING_VOLUME_ID=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:Name,Values=$VOLUME_NAME_TAG" \
    --query "Volumes[0].VolumeId" --output text)

if [ -z "$EXISTING_VOLUME_ID" ] ; then
    echo "Cannot get volume informations. Exiting."
    exit 1
fi

# If no volume found, create a new volume
if [ "$EXISTING_VOLUME_ID" == "None" ]; then
    log_message "No volume with tag Name=$VOLUME_NAME_TAG found. Creating a new volume."
    EXISTING_VOLUME_ID=$(aws ec2 create-volume --region "$REGION" \
        --availability-zone "$AVAILABILITY_ZONE" --size $VOLUME_SIZE --volume-type $VOLUME_TYPE \
        --iops $IOPS --throughput $THROUGHPUT \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$VOLUME_NAME_TAG}]" \
        --query "VolumeId" --output text)

    if [ -z "$EXISTING_VOLUME_ID" ]; then
        log_message "Failed to create the volume."
        exit 1
    else
        log_message "Created volume with ID $EXISTING_VOLUME_ID."
    fi
else
    log_message "Found existing volume with ID $EXISTING_VOLUME_ID and tag Name=$VOLUME_NAME_TAG."
fi

# Attach the volume to the instance if it is not already attached
if ! lsblk | grep -q "$VOLUME"; then
    log_message "Attaching volume $EXISTING_VOLUME_ID to $INSTANCEID at $VOLUME."
    aws ec2 attach-volume --region "$REGION" --volume-id "$EXISTING_VOLUME_ID" \
        --instance-id "$INSTANCEID" --device "$VOLUME"

    if [ $? -ne 0 ]; then
        log_message "Failed to attach volume $EXISTING_VOLUME_ID."
        exit 1
    else
        # Loop until the volume is attached
        while true; do
            # Describe the volume and check its attachment status
            ATTACHMENT_STATUS=$(aws ec2 describe-volumes --region "$REGION" --volume-id "$EXISTING_VOLUME_ID" \
                --query "Volumes[0].Attachments[0].State" --output text)

            if [ "$ATTACHMENT_STATUS" == "attached" ]; then
                echo "Volume $EXISTING_VOLUME_ID is now attached to instance $INSTANCEID."
                break
            fi

            # Optionally, add a short sleep to avoid overwhelming AWS with requests
            sleep 2
        done
    fi
else
    log_message "Volume $EXISTING_VOLUME_ID is already attached."
fi



# Check if the volume has a filesystem
FS_TYPE=$(lsblk -f | grep "^$(basename $VOLUME)" | awk '{print $2}')
if [ -z "$FS_TYPE" ]; then
    log_message "The volume $VOLUME is not formatted. Formatting now..."
    mkfs --type=$FILESYSTEM_TYPE $VOLUME || { log_message "Formatting failed."; exit 1; }
    log_message "Formatting complete."
else
    log_message "The volume $VOLUME is already formatted with $FS_TYPE."
fi

# Create the mount point directory if it doesn't exist
if [ ! -d "$MOUNT_POINT" ]; then
    log_message "Creating mount point $MOUNT_POINT"
    mkdir -p "$MOUNT_POINT" || { log_message "Failed to create mount point."; exit 1; }
fi

# Mount the volume
log_message "Mounting $VOLUME to $MOUNT_POINT"
if ! mount $VOLUME "$MOUNT_POINT"; then
  log_message "Error mounting $VOLUME to $MOUNT_POINT."
  exit 1
fi

# Ensure the volume mounts automatically on reboot by adding it to /etc/fstab
if ! grep -q "$VOLUME" /etc/fstab; then
    echo "$VOLUME $MOUNT_POINT $FILESYSTEM_TYPE defaults,nofail 0 2" | tee -a /etc/fstab > /dev/null
    log_message "Added $VOLUME to /etc/fstab for automatic mounting on reboot."
else
    log_message "$VOLUME is already in /etc/fstab."
fi

# ========================================================================
# Section: GIT Repo Cloning
# ========================================================================

# Install git
log_message "Installing Git"
yum update -y || { log_message "WARNING:Failed to update packages"; }
yum install git -y || { log_message "Failed to install git"; exit 1; }
log_message "Git successfully installed."


# Create temporary directory
log_message "Creating temporary deployment directory: ${TMP_DIR}"
mkdir -p "${TMP_DIR}" || { log_message "Failed to create directory: ${TMP_DIR}"; exit 1; }

# Copy secret key from S3
log_message "Getting GitHub deploy key from ${GIT_SECRET_S3_LOC}"
aws s3 cp "${GIT_SECRET_S3_LOC}" "${GIT_SECRET_LOCAL_LOC}" || { log_message "Failed to copy secret key from S3"; exit 1; }

# Set permissions for the private key
log_message "Setting permissions for the private key: ${GIT_SECRET_LOCAL_LOC}"
chmod -v 700 "${GIT_SECRET_LOCAL_LOC}" || { log_message "Failed to set permissions on ${GIT_SECRET_LOCAL_LOC}"; exit 1; }
log_message "Private key for GitHub access copied"

# Clone the repository
log_message "Start cloning ${REPO}"
GIT_SSH_COMMAND="ssh -i ${GIT_SECRET_LOCAL_LOC} -o StrictHostKeyChecking=no"
GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" git clone "${REPO}" "${REPO_CLONE_DIR}" || { log_message "error: Failed to clone"; exit 1; }
log_message "Repo successfully cloned to ${REPO_CLONE_DIR}"

# Remove the private key
log_message "Removing private key: ${GIT_SECRET_LOCAL_LOC}"
rm -f "${GIT_SECRET_LOCAL_LOC}" || { log_message "Failed to remove private key: ${GIT_SECRET_LOCAL_LOC}"; exit 1; }
log_message "log: GitHub Deploy Key (Private) removed"

# ========================================================================
# Section: TW via Docker Install
# ========================================================================
sleep 5

yum update -y || { log_message "WARNING:Failed to update packages"; }
yum install docker -y || { log_message "Failed to install docker"; exit 1; }

TW_DATA_LOC="${MOUNT_POINT}/tiddlywiki/"

mkdir -pv /etc/tiddlywiki/ "${TW_DATA_LOC}" || { log_message "Failed to create directory for TW"; exit 1; }

cp -v "${REPO_CLONE_DIR}/tw/tiddlywiki.service" /etc/systemd/system/
cp -v "${REPO_CLONE_DIR}/tw/tiddlywiki.conf" /etc/tiddlywiki/

cp -v "${REPO_CLONE_DIR}/tw/tw_credentials.csv" "${TW_DATA_LOC}"
cp -v "${REPO_CLONE_DIR}/tw/tw_key.pem" "${TW_DATA_LOC}"
cp -v "${REPO_CLONE_DIR}/tw/tw_server.crt" "${TW_DATA_LOC}"


systemctl daemon-reload
systemctl enable docker.service
systemctl start docker.service

sleep 5

docker volume create --name tiddlywiki --opt type=none --opt device="${TW_DATA_LOC}" --opt o=bind
docker build --no-cache -t "dce/tiddlywiki:latest" "${REPO_CLONE_DIR}/tw/docker/"

systemctl enable tiddlywiki.service
systemctl start tiddlywiki.service

rm -rfv "${TMP_DIR}"

exit 0


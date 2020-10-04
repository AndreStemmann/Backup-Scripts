#!/bin/bash -
#===============================================================================
#
#          FILE: backup_compress_and_save.sh
#
#         USAGE: ./backup_compress_and_save.sh
#
#   DESCRIPTION: Takes uncompressed Backup from Debian based OS and saves it
#                Compressed in Level0 or Level1-Backups, rotate Backup-Files
#
#       OPTIONS: Variables: SOURCE,DEST,LOG*
#  REQUIREMENTS: Uncompressed Backup, created by backup_collect_and_copy.sh
#          BUGS: ---
#         NOTES: Meant to run on Server-Side (e.g. NAS)
#                corresponding root cronjob e.g.:
#                0 4 * * 6 /bin/bash /root/backup_configs/backup_compress_and_save.sh
#        AUTHOR: Andre Stemmann
#  ORGANIZATION:
#       CREATED: 23.09.2020 17:27
#      REVISION: v1.2
#===============================================================================

# ===============================================================================
# BASE VARIABLES
# ===============================================================================
set -o errexit
set -o nounset
set -o pipefail
TODAY=$(date +%Y%m%d)
start=$(date +%s)
PROGGI=$(basename "$0")
READLINK=$(readlink -f "$0")
BASEDIR=$(dirname "$READLINK")
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Expected Backup Source
SOURCE="/samba/share/backup"

# Backup Destination
DEST="/data/backup"

# Logfile Setup
LOGPATH="/var/log/backup"
LOGFILE="${LOGPATH}/${PROGGI}-${TODAY}.log"
ERRORLOG="${LOGPATH}/${PROGGI}-${TODAY}_ERROR.log"

# ===============================================================================
# BASE FUNCTIONS
# ===============================================================================

function log () {
		echo -e "$PROGGI ; $(date '+%Y%m%d %H:%M:%S') ; $*\n" | tee -a "${LOGFILE}"
}

function errorlog () {
		echo -e "${PROGGI}_ERRORLOG ; $(date '+%Y%m%d %H:%M:%S') ; $*\n" | tee -a "${ERRORLOG}"
}

function usercheck () {
		if [[ $UID -ne 0 ]]; then
				errorlog "ERROR: ...Become user root and try again"
				exit 1
		fi
}

function folder () {
		if [ ! -d "$1" ]; then
				mkdir -p "$1"
				log "INFO: ...Create folder structure $1"
		else
				log "INFO: ...Folder $1 already exists"
		fi
}

function check_flag () {
		# check created flag file from copy_and_collect.sh
		if [ -f "${SOURCE}"/backup.flag ]; then
				log "INFO: ...Flagfile of new uncompressed Backup in place, proceeding"
				BACKUPNAME=$(head -n1 "${SOURCE}"/backup.flag)
				BACKUPDATE=$(tail -n1 "${SOURCE}"/backup.flag)
				log "INFO: ...Backupname: ${BACKUPNAME}, date: ${BACKUPDATE}"
		else
				errorlog "ERROR: ...No flagfile found"
				errorlog "ERROR: ...Aborting."
				exit 1
		fi
}

function freespace () {
		# check if raid is available and has sufficient space
		if grep 'active' /proc/mdstat; then
				mp=$(grep "active" /proc/mdstat|cut -d" " -f1)
				log "INFO: ...RAID is online"
				if mount |grep "${mp}"; then
						log "INFO: ...RAID is mounted"
						freespace=$(df -BK | grep -E "^/dev/${mp}" | awk '{print $4}'|tr -d 'K')
						tosave=$(du -sk "${SOURCE}"/"${BACKUPNAME}"|awk '{print $1}')
						tosavegb=$((tosave/1024/1024))
						freegb=$((freespace/1024/1024))
						if [ "$tosave" -ge "$freespace" ]; then
								errorlog "ERROR: ...Not enough free space for backup creation"
								df -h
								exit 1
						else
								log "INFO: ...Backup Size: ${tosavegb}GB, Free Storage: ${freegb}GB"
						fi
				else
						errorlog "ERROR: ...RAID is not mounted"
						errorlog "$(mount|column -t)"
						exit 1
				fi
		else
				errorlog "ERROR: ...RAID is not active"
				errorlog "$(cat /proc/mdstat)"
				exit 1
		fi
}

function zipper () {
		# create compressed archive from sourcefiles, whether full or incremental
		log "INFO: ...Creating archive from ${SOURCE}/${BACKUPNAME}"
		INCREMENTAL="${BASEDIR}/snapshot_${BACKUPNAME}.file"
		if [ -f "$INCREMENTAL" ]; then
				log "INFO: ...Level 0 (Full-Backup) already taken. Going on with Level 1 (incremental)"
				Level="Incremental"
		else
				log "INFO: ...No snapshot file found, assuming an inital Full-Backup"
				Level="Full"
		fi
		log "INFO: ...Will pack the sourcefiles as tar.bz2"
		cd "${SOURCE}"
		if ! tar -cjv --checkpoint=50000 --checkpoint-action=echo="#%u: %T" -g "${INCREMENTAL}" -f "${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 "${BACKUPNAME}" 2>&1 | tee "${LOGFILE}"; then
				errorlog "ERROR: ...Failed to create tar.gz-archive from sourcefiles"
				errorlog "ERROR: ...Please re-check manually: ${SOURCE}"
				exit 1
		else
				log "INFO: ...Checking tarball creation"
				if [ -f "${SOURCE}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 ]; then
						log "INFO: ...Archive creation for ${BACKUPNAME} was successfull"
				else
						errorlog "ERROR: ...No Backup-File in place!"
						errorlog "ERROR: ...Aborting"
				fi

		fi
    end=$(date +%s)
    runtime=$((end-start))
    log "...Local Archive creation took $runtime Seconds"
}

function copy2dest () {
		# copy compressed archive to final destination
		log "INFO: ...Testing rsync ${BACKUPNAME}_${Level}_${BACKUPDATE}.tar.bz2 to ${DEST}"
		if rsync --dry-run -avz --stats --progress  --log-file="${LOGFILE}" "${SOURCE}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 "${DEST}"/; then
				log "INFO: ...Test rsync successfull, starting real rsync"
				if rsync -avz --stats --progress  --log-file="${LOGFILE}" "${SOURCE}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 "${DEST}"/; then
						log "INFO: ...Real rsync successfull"
				else
						errorlog "ERROR: ...Real rsync failed. Please re-check manually: ${DEST}"
						errorlog "ERROR: ...Aborting"
						exit 1
				fi
		else
				errorlog "ERROR: ...Test rsync failed"
				errorlog "ERROR: ...Aborting"
				exit 1
		fi
}

function tidyup () {
		# remove created compressed archive from source after successfull rsync
		if [ -f "${DEST}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 ]; then
				log "INFO: ...Compressed backup is in place under: ${DEST}"
				if [ -f "${SOURCE}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2 ]; then
						if rm "${SOURCE}"/"${BACKUPNAME}"_"${Level}"_"${BACKUPDATE}".tar.bz2; then
								log "INFO: ...Successfully removed compressed archive from: ${SOURCE}"
						else
								errorlog "ERROR: ...Failed to remove compressed backupfile from source!"
								errorlog "ERROR: ...Please re-check manually: ${SOURCE}"
						fi
				else
						log "INFO: ...Compressed Backupfile already removed from: ${SOURCE}"
				fi
		else
				errorlog "ERROR: ...Compressed Backupfile is NOT in place under: ${DEST}!"
				errorlog "ERROR: ...Please re-check manually. aborting"
				exit 1
		fi

}

function rotate_full () {
		# Full-Backup Retention: 60 Days
    if [ "$(find ${DEST} -type f -name "${BACKUPNAME}_Full*.bz2" -mtime +60|wc -l)" -eq 1 ]; then
				log "INFO: ...The last Full-Backup is older than 60 Days"
				log "INFO: ...The next Backup will be another Full-Backup"
				log "INFO: ...Deleting the snapshot-File for tar: ${INCREMENTAL}"
				if rm -f "${INCREMENTAL}"; then
						log "INFO: ...Deletion of ${INCREMENTAL} was successfull"
				else
						errorlog "ERROR: ...Deletion of ${INCREMENTAL} failed"
						errorlog "ERROR: ...Please re-check manually!"
				fi
		fi

		# Keep only one Full-Backup per 60 Days
		if [ "$(find ${DEST} -type f -name "${BACKUPNAME}_Full*.bz2"|wc -l)" -gt 1 ]; then
				full_backup_rotate="yes"
				log "INFO: ...Detected more than one Full-Backup"
				log "INFO: ...Will delete the old Full-Backup now"
				if rm -f "$(ls -t "${DEST}/{BACKUPNAME_Full*.bz2"|tail -n -1)"; then
						log "INFO: ...Successfully deleted old Full-Backup"
				else
						errorlog "ERROR: ...Failed to delete old Full-Backup"
						errorlog "ERROR: ...Please re-check manually: ${DEST}"
				fi
		fi
}

function rotate_incremental () {
		if [ "$full_backup_rotate" = "yes" ];then
				log "INFO: ...Detected Full-Backup Rotation."
				log "INFO: ...Deleting corresponding Incremental Backups now:"
				log "INFO: ...$(find ${DEST} -type f -name "${BACKUPNAME}_Incremental*")"
				if find ${DEST} -type f -name "${BACKUPNAME}_Incremental*" -delete; then
						log "INFO: ...Deletion of Incremental Backups was successfull"
				else
						errorlog "ERROR: ...Deletion of Incremental Backups failed!"
						errorlog "ERROR: ...Please re-check manually: ${DEST}"
				fi
		else
				# Keep only two Incremental Backups, delete the older ones
				if [[ "$(find ${DEST} -type f -name "${BACKUPNAME}_Incremental*" -printf '.'|wc -c)" -ge 3 ]]; then
						log "INFO: ...Found old Incremental Backup(s): $(ls -t "${DEST}/*_Incremental*"|tail -n -2)"
						log "INFO: ...Will delete them"
						if rm -f "$(ls -t "${DEST}/*_Incremental*"|tail -n -2)"; then
								log "INFO: Removal of old Incremental Backups was successfull"
						else
								errorlog "ERROR: ...Removal of old Incremental Backups failed"
								errorlog "ERROR: ...Please re-check manually: ${DEST}"
						fi
				fi
		fi
}

function rotate_logs () {
		if [[ "$(find ${LOGPATH} -type f -name "${PROGGI}-*.log" -printf '.'|wc -c)" -ge 3 ]]; then
				log "INFO: ...Found old Logfiles: $(ls -t "${LOGPATH}/${PROGGI}-*.log"|tail -n -2)"
				log "INFO: ...Will delete them"
				if rm -f "$(ls -t "${LOGPATH}/${PROGGI}-*.log"|tail -n -2)"; then
						log "INFO: Removal of old Logfiles was successfull"
				else
						errorlog "ERROR: ...Removal of old Logfiles failed"
						errorlog "ERROR: ...Please re-check manually: ${LOGPATH}"
				fi
		fi
		if [[ "$(find ${LOGPATH} -type f -name "${PROGGI}-*_ERROR.log" -printf '.'|wc -c)" -ge 3 ]]; then
				log "INFO: ...Found old ERROR-Logfiles: $(ls -t "${LOGPATH}/${PROGGI}-*_ERROR.log"|tail -n -2)"
				log "INFO: ...Will delete them"
				if rm -f "$(ls -t "${LOGPATH}/${PROGGI}-*_ERROR.log"|tail -n -2)"; then
						log "INFO: Removal of old ERROR-Logfiles was successfull"
				else
						errorlog "ERROR: ...Removal of old ERROR-Logfiles failed"
						errorlog "ERROR: ...Please re-check manually: ${LOGPATH}"
				fi
    fi
}

##################
#    MAIN RUN    #
##################
folder "${LOGPATH}"
folder "${DEST}"
usercheck
check_flag
freespace
zipper
log "BACKUP-CONFIG"
log "#########################"
log "logfile location: $LOGPATH"
log "local backup source: $SOURCE"
log "tar snapshot file: $INCREMENTAL"
log "local backup destination: $DEST"
log "date: $TODAY"
copy2dest
tidyup
rotate_full
rotate_incremental
rotate_logs
arsize=$(du -shx "${DEST}"/"${BACKUPNAME}"_"${Level}"_"${TODAY}".tar.bz2)
log "INFO: ...Compressed Archive Size on Destination: ${arsize}"
log "INFO: ...Remaining free Space: $(df -h|grep "${mp}"|awk '{print $4}')"
if rm "${SOURCE}"/backup.flag; then
		log "INFO: Removal of backup.flag was successfull"
else
		errorlog "ERROR: ...Removal of ${SOURCE}/backup.flag failed"
		errorlog "ERROR: ...Please re-check manually: ${SOURCE}"
fi
end=$(date +%s)
runtime=$((end-start))
if [ "$(echo runtime|wc -c)" -le 2 ]; then
		log "INFO: ...Script Runtime: $runtime Seconds"
elif [ "${#runtime}" -le 3 ]; then
		min=$((runtime/60))
		log "INFO: ...Script Runtime: $min Minutes"
elif [ "${#runtime}" -ge 4 ]; then
		hrs=$((runtime/60/60))
		log "INFO: ...Script Runtime: $hrs Hours"
fi
exit 0

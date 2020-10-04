
#!/bin/bash -
#===============================================================================
#
#          FILE: backup_collect_and_copy.sh
#
#         USAGE: ./backup_collect_and_copy.sh
#
#   DESCRIPTION: small script to backup relevant files uncompressed to samba share
#
#       OPTIONS: Variables: SMB*,FLATFILES,CONFIGFOLDERS,EXCLUDEFILE LOG*
#  REQUIREMENTS: online, attached smb-share, Rsync exclude file
#          BUGS: ---
#         NOTES: Obviously to run on your backup-source (e.g. Ubuntu Notebook)
#        AUTHOR: Andre Stemmann
#  ORGANIZATION:
#       CREATED: 22.09.2020 14:27
#      REVISION: 1.0
#===============================================================================

# ===============================================================================
# BASE VARIABLES
# ===============================================================================

# Script Contstants
set -o errexit
set -o nounset
set -o pipefail
TODAY=$(date +%Y%m%d)
start=$(date +%s)
HOST=$(hostname -f)
PROGGI=$(basename "$0")
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
READLINK=$(readlink -f "$0")
BASEDIR=$(dirname "$READLINK")
. /etc/os-release
BACKUPNAME="${HOST}"_"${ID}"

# Mount Point of Remote Storage
SMBIP="1.2.3.3"
SMBDIR="/samba/share"
SMBMOUNT="/mnt/mount/point"

# Rsync Options
FLATFILES=("/home/user/pictures" "/home/user/documents")
CONFIGFOLDERS=("/etc" "/var" "/opt")
EXCLUDEFILE="${BASEDIR}/exclude_from_rsync.txt"

# Logfile Setup
LOGPATH="/var/log/backup_notebook"
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

function check_mount () {
    if mount|grep "${SMBIP}"; then
        log "INFO: ...Samba-Share is mounted"
    else
        log "INFO: ...Samba-Share is not mounted, will do it now"
        if mount -t cifs -o username=nobody //"${SMBIP}"/"${SMBDIR}" "${SMBMOUNT}"; then
            log "INFO: ...Mounted ${SMBIP}/${SMBDIR} to ${SMBMOUNT}"
        else
            errorlog "ERROR: ...Failed to mount ${SMBIP}/${SMBDIR} to ${SMBMOUNT}"
            errorlog "ERROR: ...Aborting!"
            exit 1
        fi
    fi
}

function freespace () {
    freespace=$(df -BK|grep -E "^//${SMBIP}"|awk '{print $4}'|tr -d 'K')
    for element in "${FLATFILES[@]}"
    do
        result1=$(du -sk "$element"|cut -d"/" -f1)
        calcarr1+=("$result1")
    done
    sum1=$(IFS=+; echo "$((${calcarr1[*]}))")
    for element in "${CONFIGFOLDERS[@]}"
    do
        result2=$(du -sk "$element"|cut -d"/" -f1)
        calcarr2+=("$result2")
    done
    sum2=$(IFS=+; echo "$((${calcarr2[*]}))")
    tosave=$((sum1+sum2))
    tosavegb=$((tosave/1024/1024))
    freegb=$((freespace/1024/1024))
    if [ "$tosave" -ge "$freespace" ]; then
        errorlog "ERROR: ...Not enough free space for remote backup creation"
        errorlog "ERROR: ...Free space left on ${SMBIP}:${freegb}GB. Backupsize:${tosavegb}GB."
        exit 1
    else
        log "INFO: ...Backup Size:${tosavegb}GB, Free Storage on Server:${freegb}GB"
    fi
}

function backup () {
    log "INFO: ...Gathering smb-share availability"
    if ping -c3 "${SMBIP}"; then
        log "INFO: ...Samba-Share online, test mountpoint ${SMBMOUNT}"
        if mount|grep "//${SMBIP}"; then
            log "INFO: ...Samba-Share mounted,start copy of files"
            # DPKG/APT Configs to Backup
            PKG_CONFIGS=("APT" "APT-KEYS" "DPKG")
            for x in ${PKG_CONFIGS[*]}; do folder "${SMBMOUNT}"/"${BACKUPNAME}"/PKG_CONFIGS/"${x}" ; done
            log "INFO: ...Copy Package Management config-files"
            if dpkg --get-selections > "${SMBMOUNT}"/"${BACKUPNAME}"/PKG_CONFIGS/DPKG/DPKG-get-selections.list; then
                log "INFO: ...Copy dpkg infos"
            else
                errorlog "ERROR: ...Copy of dpkg infos failed"
            fi
            if apt-mark showauto > "${SMBMOUNT}"/"${BACKUPNAME}"/PKG_CONFIGS/APT/APT_get_auto.list; then
                log "INFO: ...Copy apt-mark showauto infos"
            else
                errorlog "ERROR: ...Copy of apt-mark-showauto infos failed"
            fi
            if apt-mark showmanual > "${SMBMOUNT}"/"${BACKUPNAME}"/PKG_CONFIGS/APT/APT_get_manual.list; then
                log "INFO: ...Copy apt-mark showmanual infos"
            else
                errorlog "ERROR: ...Gathering of apt-mark showmanual infos failed"
            fi
            if apt-key exportall > "${SMBMOUNT}"/"${BACKUPNAME}"/PKG_CONFIGS/APT-KEYS/Repo.keys; then
                log "INFO: ...Copy apt-key infos"
            else
                errorlog "ERROR: ...Copy of apt-key infos failed"
            fi

            # Config Folders to Backup
            folder "${SMBMOUNT}"/"${BACKUPNAME}"/CONFIGFOLDERS/
            for configfolder in ${CONFIGFOLDERS[*]}
            do
                find "${configfolder}" -type f -name '*~' -exec rm -f '{}' \;
                log "INFO: ...Rsync ${configfolder} to ${SMBMOUNT}/${BACKUPNAME}/CONFIGFOLDERS/"
                if rsync --dry-run --update -raz --stats --progress --log-file="${LOGFILE}" --exclude-from="${EXCLUDEFILE}" "${configfolder}" "${SMBMOUNT}"/"${BACKUPNAME}"/CONFIGFOLDERS/; then
                    log "INFO: ...TEST rsync successfull, starting copy of ${configfolder}"
                    if rsync --update -raz --stats --progress --log-file="${LOGFILE}" --exclude-from="${EXCLUDEFILE}" "${configfolder}" "${SMBMOUNT}"/"${BACKUPNAME}"/CONFIGFOLDERS/; then
                        log "INFO: ...Rsync of ${configfolder} successfull"
                    else
                        errorlog "ERROR: ...Rsync of ${configfolder} failed"
                    fi
                else
                    errorlog "ERROR: ...TEST rsync of ${configfolder} failed"
                fi
            done

            # Flatfiles to Backup
            folder "${SMBMOUNT}"/"${BACKUPNAME}"/FLATFILES/
            for flatfile in ${FLATFILES[*]}
            do
                find "${flatfile}" -type f -name '*~' -exec rm -f '{}' \;
                log "INFO: ...Testing Rsync ${flatfile} to ${SMBMOUNT}/${BACKUPNAME}/FLATFILES/"
                if rsync --dry-run --update -raz --stats --progress --log-file="${LOGFILE}" --exclude-from="${EXCLUDEFILE}" "${flatfile}" "${SMBMOUNT}"/"${BACKUPNAME}"/FLATFILES/; then
                    log "INFO: ...TEST rsync successfull, starting copy of ${flatfile}"
                    if rsync --update -raz --stats --progress --log-file="${LOGFILE}" --exclude-from="${EXCLUDEFILE}" "${flatfile}" "${SMBMOUNT}"/"${BACKUPNAME}"/FLATFILES/; then
                        log "INFO: ...Rsync of ${flatfile} successfull"
                    else
                        errorlog "ERROR: ...Rsync of ${flatfile} failed."
                    fi
                else
                    errorlog "ERROR: ...TEST rsync of ${flatfile} failed"
                fi
            done
        else
            errorlog "ERROR: ...Samba-Share is not mounted!"
            errorlog "ERROR: ...Aborting"
            exit 1
        fi
    else
        errorlog "ERROR: ...Samba-Share is not online!"
        errorlog "ERROR: ...Aborting"
        exit 1
    fi

    backupsize=$(du -shx "${SMBMOUNT}"/"${BACKUPNAME}"|awk '{print $1}')
    log "INFO: ...Uncompressed Backup Filesize on Samba Share: $backupsize"
    log "INFO: ...Remaining free space on Samba Share: $(df -h|grep -E "^//${SMBIP}"|awk '{print $4}')"
    end=$(date +%s)
    runtime=$((end-start))
    log "INFO: ...Rsync to samba-share took $runtime Seconds"
    log "INFO: ...Creating Flag-File for Server"
    echo "${BACKUPNAME}" > "${SMBMOUNT}"/backup.flag
    echo "${TODAY}" >> "${SMBMOUNT}"/backup.flag
    if [[ $(tail -n1 ${SMBMOUNT}/backup.flag) == "${TODAY}" ]]; then
        log "INFO: ...Flag-File creation was successfull"
    else
        errorlog "ERROR: ...Flag-File creation failed!"
        errorlog "ERROR: ...please re-check manually!"
    fi
}

# MAIN RUN
cd "$BASEDIR"
folder "${LOGPATH}"
log "CONFIG"
log "#########################"
log "logfile location: $LOGPATH"
log "remote backup location: ${SMBIP}_${SMBMOUNT}"
log "hostname: $HOST"
log "date: $TODAY"
usercheck
check_mount
freespace
backup
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

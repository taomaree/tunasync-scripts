#!/bin/bash
# requires: wget, yum-utils, timeout, md5sum
set -e
set -o pipefail

_here=`dirname $(realpath $0)`
apt_sync="${_here}/apt-sync.py" 
yum_sync="${_here}/yum-sync.py"

MAX_RETRY=${MAX_RETRY:-"3"}
DOWNLOAD_TIMEOUT=${DOWNLOAD_TIMEOUT:-"1800"}

BASE_URL="http://download.virtualbox.org/virtualbox"
BASE_PATH="${TUNASYNC_WORKING_DIR}"

YUM_PATH="${BASE_PATH}/rpm"
APT_PATH="${BASE_PATH}/apt"
export REPO_SIZE_FILE=/tmp/reposize.$RANDOM

# === download rhel packages ====

"$yum_sync" "${BASE_URL}/rpm/el/@{os_ver}/@{arch}" 7 VirtualBox x86_64 "el@{os_ver}" "$YUM_PATH"
echo "YUM finished"

# === download deb packages ====

"$apt_sync" --delete "${BASE_URL}/debian" @debian-current,@ubuntu-lts contrib,non-free amd64,i386 "$APT_PATH"
echo "Debian and ubuntu finished"

# === download standalone packages ====

timeout -s INT 30 wget ${WGET_OPTIONS:-} -q -O "/tmp/index.html" "${BASE_URL}/"
timeout -s INT 30 wget ${WGET_OPTIONS:-} -q -O "${BASE_PATH}/LATEST.TXT" "${BASE_URL}/LATEST.TXT"

for((major=4;major<=7;major++));do
	LATEST_VERSION=$(grep -P -o "\"$major\.[\\d\\.]+/\"" -r /tmp/index.html|tail -n 1)
	LATEST_VERSION=${LATEST_VERSION%/\"}
	LATEST_VERSION=${LATEST_VERSION#\"}
	[[ -z "$LATEST_VERSION" ]] && continue

	LATEST_PATH="${BASE_PATH}/${LATEST_VERSION}"

	mkdir -p ${LATEST_PATH}
	timeout -s INT 30 wget ${WGET_OPTIONS:-} -q -O "${LATEST_PATH}/MD5SUMS" "${BASE_URL}/${LATEST_VERSION}/MD5SUMS"
	timeout -s INT 30 wget ${WGET_OPTIONS:-} -q -O "${LATEST_PATH}/SHA256SUMS" "${BASE_URL}/${LATEST_VERSION}/SHA256SUMS"

	while read line; do
		read -a tokens <<< $line
		pkg_checksum=${tokens[0]}
		filename=${tokens[1]}
		filename=${filename/\*/}

		dest_filename="${LATEST_PATH}/${filename}"
		pkg_url="${BASE_URL}/${LATEST_VERSION}/${filename}"

		declare downloaded=false

		if [[ -f ${dest_filename} ]]; then
			echo "${pkg_checksum}  ${dest_filename}" | md5sum -c - && {
				downloaded=true
				echo "Skipping ${filename}"
			}
		fi
		for retry in `seq ${MAX_RETRY}`; do
			[[ $downloaded == true ]] && break
			rm ${dest_filename} || true
			echo "downloading ${pkg_url} to ${dest_filename}"
			if [[ -z ${DRY_RUN:-} ]]; then
				timeout -s INT "$DOWNLOAD_TIMEOUT" wget ${WGET_OPTIONS:-} -N -c -q -O ${dest_filename} ${pkg_url} && {
					# two space for md5sum/sha1sum/sha256sum check format
					echo "${pkg_checksum}  ${dest_filename}" | md5sum -c - && downloaded=true
				}
			else
				downloaded=true
			fi
		done
		if [[ $downloaded == false ]];then
			echo "failed to download ${pkg_url} to ${dest_filename}"
			exit 1
		fi
		stat -c "+%s" "${dest_filename}" >>$REPO_SIZE_FILE

	done < "${LATEST_PATH}/MD5SUMS"
	echo "Virtualbox ${LATEST_VERSION} finished"
done

echo "Linking the latest releases"
LATEST_VERSION=`cat "${BASE_PATH}/LATEST.TXT"`
for filename in ${BASE_PATH}/${LATEST_VERSION}/*.*; do
	case $filename in
		*Win.exe)
			ln -sf "${filename#"$BASE_PATH/"}" "${BASE_PATH}/virtualbox-Win-latest.exe"
			;;
		*OSX.dmg)
			ln -sf "${filename#"$BASE_PATH/"}" "${BASE_PATH}/virtualbox-osx-latest.dmg"
			;;
	esac
done

"${_here}/helpers/size-sum.sh" $REPO_SIZE_FILE --rm

#!/bin/sh
# Copyright (c) 2016 Lucio Andrés Illanes Albornoz <l.illanes@gmx.de>
#

. ./build.subr;
VALID_BUILD_LEVELS="fetch,extract,build_dir,autoconf,patch,configure,clean,build,install";

#
# Process command line arguments.
while [ ${#} -gt 0 ]; do
case ${1} in
-c)	ARG_CLEAN=1; ;;
-t*)	ARG_TARBALL=1; [ "${1#-t.}" != "${1}" ] && TARBALL_SUFFIX=${1#-t.}; ;;
-x)	ARG_XTRACE=1; set -o xtrace; ;;
-a)	[ -z "${2}" ] && exec cat build.usage || ARCH="${2}"; shift; ;;
-b)	[ -z "${2}" ] && exec cat build.usage || BUILD="${2}"; shift; ;;
-i)	[ -z "${2}" ] && exec cat build.usage || insert_build_script_link "${2}"; exit; ;;
-r)	[ -n "${ARG_RESTART_SCRIPT}" ] && exec cat build.usage;
	if [ "${2#*:*}" != "${2}" ]; then
		ARG_RESTART_SCRIPT="${2%%:*}"; ARG_RESTART_SCRIPT_AT="${2##*:}";
		if [ ! -e "${ARG_RESTART_SCRIPT}" ]; then
			log_msg fail "Error: unknown build script specified.";
			exec cat build.usage;
		fi;
		if [ "${ARG_RESTART_SCRIPT_AT}" != diff ]; then
			for __ in $(split , "${ARG_RESTART_SCRIPT_AT}"); do
				if ! match_list "${VALID_BUILD_LEVELS}" , "${__}"; then
					log_msg fail "Error: unknown build level specified.";
					exec cat build.usage;
				fi;
			done;
		fi;
	else
		ARG_RESTART_SCRIPT="${2}"; ARG_RESTART_SCRIPT_AT=ALL;
	fi; shift; ;;
*=*)	set_var_unsafe "${1%%=*}" "${1#*=}"; ;;
*)	exec cat build.usage; ;;
esac; shift; done;

# Source the build variables file and its local overrides, if any.
for __ in ${HOME}/midipix_build.vars ../midipix_build.vars ./build.vars; do
	[ -e ${__} ] && . ${__};
done;

#
# Clear the environment.
# Check whether the pathnames in build.vars contain non-empty valid values.
# Check whether all prerequisite command names resolve.
# Check whether all prerequisite pathnames resolve.
for __ in $(export | sed -e 's/^export //' -e 's/=.*$//'); do
	if ! match_list "${CLEAR_ENV_VARS_EXCEPT}" " " "${__}"; then
		unset "${__}";
	fi;
done;
for __ in ${CHECK_PATH_VARS}; do
	if [ -z "${___:=$(get_var_unsafe "${__}")}" ]; then
		log_msg failexit "Error: variable \`${__}' is empty or unset.";
	elif [ "${___#* *}" != "${___}" ]; then
		log_msg failexit "Error: variable \`${__}' contains one or more whitespace characters.";
	fi;
done;
for __ in ${CHECK_PREREQ_CMDS} ${CHECK_PREREQ_FILES}; do
	if [ "${__#/}" != "${__}" ]; then
		if [ ! -e "${__}" ]; then
			log_msg fail "Error: missing prerequisite file \`${__}'.";
			__exit=1;
		fi;
	else
		if ! test_cmd "${__}"; then
			log_msg fail "Error: missing prerequisite command \`${__}'.";
			__exit=1;
		fi;
	fi;
done;
if [ ${__exit:-0} = 1 ]; then
	exit 1;
elif [ -n "${__exit}" ]; then
	unset __exit;
fi;

# Clean ${PREFIX} if requested.
if [ ${ARG_CLEAN:-0} -eq 1 ]; then
	log_msg info "-c specified, cleaning prefix...";
	for __ in ${CLEAR_PREFIX_DIRS}; do
		if [ -e ${PREFIX}/${__} ]; then
			rm -rf -- ${PREFIX}/${__};
		fi;
	done;
fi;

# Create directory hierarchy and usr -> . symlinks.
mkdir -p -- ${PREFIX} ${PREFIX_NATIVE} ${PREFIX_CROSS} ${PREFIX_TARGET}/lib ${DLCACHEDIR} ${WORKDIR};
for __ in ${PREFIX}/usr ${PREFIX_NATIVE}/usr; do
	if [ ! -L "${__}" ]; then
		rm -rf -- "${__}"; ln -sf -- . "${__}";
	fi;
done;

if [ -e ${BUILD_LOG_FNAME} ]; then
	mv -- ${BUILD_LOG_FNAME} ${BUILD_LOG_LAST_FNAME};
fi;
touch ${BUILD_STATUS_IN_PROGRESS_FNAME};
trap "rm -f ${BUILD_STATUS_IN_PROGRESS_FNAME}; log_msg failexit \"Build aborted.\"" HUP INT TERM USR1 USR2;

{(
trap "rm -f ${BUILD_STATUS_IN_PROGRESS_FNAME}; log_msg failexit \"Build aborted.\"" HUP INT TERM USR1 USR2;
BUILD_DATE_START="$(date %Y-%m-%d-%H-%M-%S)";
BUILD_NFINI=${BUILD_NSKIP:=${BUILD_NFAIL:=${BUILD_NBUILT:=0}}};
BUILD_TIMES_SECS=$(command date +%s);
log_msg info "Build started by ${BUILD_USER:=${USER}}@${BUILD_HNAME:=$(hostname)} at ${BUILD_DATE_START}.";
log_env_vars "build (global)" ${LOG_ENV_VARS};

for BUILD_LVL in 0 1 2 3 ${ARG_TARBALL:+9}; do
	for BUILD_SCRIPT_FNAME in ${BUILD_LVL}[0-9][0-9].*.build; do
		if [ -n "${ARG_RESTART_SCRIPT}" ]					\
		&& [ "${ARG_RESTART_SCRIPT}" != "ALL" ]					\
		&& [ "${ARG_RESTART_SCRIPT}" != ${BUILD_SCRIPT_FNAME} ]; then
			if [ ${ARG_XTRACE:-0} -eq 0 ]; then
				log_msg info "Skipped build script \`${BUILD_SCRIPT_FNAME}' (--build-scripts policy.)";
			fi;
			continue;
		elif [ ! -f "${BUILD_SCRIPT_FNAME}" ]; then
			log_msg info "Build script \`${BUILD_SCRIPT_FNAME}' non-existent or not a file.";
			continue;
		else
			unset BUILD_SCRIPT_RC; : $((BUILD_NBUILT+=1));
			if [ "${ARG_RESTART_SCRIPT}" != ALL ]\
			&& is_build_script_done finish "${BUILD_SCRIPT_FNAME%.build}"; then
				log_msg info "Skipped build script \`${BUILD_SCRIPT_FNAME}' (already built.)";
					: $((BUILD_NSKIP+=1)); BUILD_SCRIPT_RC=0; continue;
			fi;
			log_msg info "Invoking build script${ARG_RESTART_SCRIPT:+ (forcibly)} \`${BUILD_SCRIPT_FNAME}'${ARG_RESTART_SCRIPT_AT:+ at build step ${ARG_RESTART_SCRIPT_AT}}.";
			(set -o errexit -o noglob;					\
			 set -- $(split . ${BUILD_SCRIPT_FNAME%%.build*});		\
			 SCRIPT_FNAME=${BUILD_SCRIPT_FNAME};				\
			 SCRIPT_NAME=${SCRIPT_FNAME%%.build*};				\
			 export PKG_BUILD=${BUILD};					\
			 export PKG_TARGET=${TARGET};					\
			 export PKG_PREFIX=$(get_var_unsafe PKG_LVL${BUILD_LVL}_PREFIX);\
			 export MIDIPIX_BUILD_PWD=$(pwd); cd ${WORKDIR};		\
			 for SCRIPT_SOURCE in build.subr ${SCRIPT_NAME}.vars		\
					${BUILD_SCRIPT_FNAME}; do			\
			 	[ -f ${MIDIPIX_BUILD_PWD}/${SCRIPT_SOURCE} ] &&		\
					 . ${MIDIPIX_BUILD_PWD}/${SCRIPT_SOURCE};	\
			 done);
			case ${BUILD_SCRIPT_RC:=${?}} in
			0) log_msg succ "Finished build script \`${BUILD_SCRIPT_FNAME}'.";
				: $((BUILD_NFINI+=1)); continue; ;;
			*) log_msg fail "Build failed in build script \`${BUILD_SCRIPT_FNAME}' (last return code ${BUILD_SCRIPT_RC}.).";
				: $((BUILD_NFAIL+=1)); break; ;;
			esac;
		fi;
	done;
	if [ ${BUILD_SCRIPT_RC:-0} -ne 0 ]; then
		break;
	fi;
done;

log_msg info "${BUILD_NFINI} finished, ${BUILD_NSKIP} skipped, and ${BUILD_NFAIL} failed builds in ${BUILD_NBUILT} build script(s).";
: $((BUILD_TIMES_SECS=$(command date +%s)-${BUILD_TIMES_SECS}));
: $((BUILD_TIMES_HOURS=${BUILD_TIMES_SECS}/3600));
: $((BUILD_TIMES_MINUTES=(${BUILD_TIMES_SECS}%3600)/60));
: $((BUILD_TIMES_SECS=(${BUILD_TIMES_SECS}%3600)%60));
log_msg info "Build time: ${BUILD_TIMES_HOURS} hour(s), ${BUILD_TIMES_MINUTES} minute(s), and ${BUILD_TIMES_SECS} second(s).";

if [ -f "${BUILD_STATUS_IN_PROGRESS_FNAME}" ]; then
	rm -f -- ${BUILD_STATUS_IN_PROGRESS_FNAME};
fi;

exit ${BUILD_SCRIPT_RC})} 2>&1 | tee ${BUILD_LOG_FNAME} &
trap "kill -INT $!" HUP INT TERM USR1 USR2; wait;

# vim:filetype=sh

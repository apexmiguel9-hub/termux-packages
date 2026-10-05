#!/usr/bin/env bash
# shellcheck disable=SC2039,SC2059

# Title:         build-bootstrap.sh
# Description:   A script to build bootstrap archives for the termux-app
#                from local package sources instead of debs published in
#                apt repo like done by generate-bootstrap.sh. It allows
#                bootstrap archives to be easily built for (forked) termux
#                apps without having to publish an apt repo first.
# Usage:         run "build-bootstrap.sh --help"
version=0.1.0

set -e

export TERMUX_SCRIPTDIR=$(realpath "$(dirname "$(realpath "$0")")/../")
: "${TERMUX_TOPDIR:="$HOME/.termux-build"}"
. "${TERMUX_SCRIPTDIR}"/scripts/properties.sh
. "${TERMUX_SCRIPTDIR}"/scripts/build/termux_step_handle_buildarch.sh

BOOTSTRAP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tmp.XXXXXXXX")

# By default, bootstrap archives are compatible with Android >=7.0
# and <10.
BOOTSTRAP_ANDROID10_COMPATIBLE=false

# By default, bootstrap archives will be built for all architectures
# supported by Termux application.
# Override with option '--architectures'.
TERMUX_DEFAULT_ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")
TERMUX_ARCHITECTURES=("${TERMUX_DEFAULT_ARCHITECTURES[@]}")

# FORK PATCH (bootstrap propio): estas rutas estaban fijas a las del contenedor
# de build, lo que impedia ejecutarlo fuera de /home/builder y desde CI, donde el
# repo vive en otro sitio y los .deb se dejan en ./output. Con ${VAR:=default}
# se pueden inyectar por entorno y los valores por defecto siguen siendo los
# del docker builder.
: "${TERMUX_PACKAGES_DIRECTORY:=/home/builder/termux-packages}"
: "${TERMUX_BUILT_DEBS_DIRECTORY:=$TERMUX_PACKAGES_DIRECTORY/output}"
: "${TERMUX_BUILT_PACKAGES_DIRECTORY:=/data/data/.built-packages}"
TERMUX_PACKAGES_DIRECTORY=$(realpath "$TERMUX_PACKAGES_DIRECTORY")

IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR=1
FORCE_BUILD_PACKAGES=0

# A list of packages to build
declare -a PACKAGES=()

# A list of non-essential packages to build.
# By default it is empty, but can be filled with option '--add'.
declare -a ADDITIONAL_PACKAGES=()

# A list of already extracted packages
declare -a EXTRACTED_PACKAGES=()

# A list of options to pass to build-package.sh
declare -a BUILD_PACKAGE_OPTIONS=()

# Check for some important utilities that may not be available for
# some reason.
for cmd in ar awk curl grep gzip find sed tar xargs xz zip; do
	if [ -z "$(command -v $cmd)" ]; then
		echo "[!] Utility '$cmd' is not available in PATH."
		exit 1
	fi
done

# FORK PATCH (bootstrap propio): resuelve un nombre de paquete al directorio
# de fuentes que hay que compilar.
#
# El script upstream nunca necesita esto porque descarga .deb ya compilados
# del repo. Aqui compilamos desde fuente, y 305 paquetes del repo son
# SUBpaquetes: no tienen directorio propio, se declaran como
# packages/<padre>/<nombre>.subpackage.sh y los produce build-package.sh al
# compilar el padre. El caso que rompe el bootstrap es 'bzip2', que es un
# subpaquete de 'libbz2':
#
#   ERROR: No package bzip2 found in any of the enabled repositories.
#
# que es exactamente lo que fallo el run 37216882019.
#
# Se imprime el nombre del paquete a compilar por stdout, para no contaminar
# la salida de build-package.sh que se captura en build_package().
resolve_package_dir() {
	local name="$1"
	if [ -d "$TERMUX_PACKAGES_DIRECTORY/packages/$name" ]; then
		printf '%s\n' "$name"
		return 0
	fi
	local candidate
	for candidate in "$TERMUX_PACKAGES_DIRECTORY"/packages/*/"$name.subpackage.sh"; do
		[ -e "$candidate" ] || continue
		printf '%s\n' "$(basename "$(dirname "$candidate")")"
		return 0
	done
	return 1
}

# Build deb files for package and its dependencies deb from source for arch
build_package() {

	local return_value

	local TERMUX_ARCH="$1"
	local package_name="$2"

	local build_output
	local source_pkg

	# FORK PATCH: un subpaquete (bzip2) no tiene directorio propio; se compila
	# su padre (libbz2), que produce ambos .deb.
	if ! source_pkg=$(resolve_package_dir "$package_name"); then
		echo "[!] No source directory for '$package_name' (not a package nor a subpackage?)" 1>&2
		return 1
	fi
	if [ "$source_pkg" != "$package_name" ]; then
		echo "[*] '$package_name' is a subpackage of '$source_pkg'; building the parent"
	fi

	# FORK PATCH: reutilizar un .deb ya compilado.
	#
	# Compilar el closure entero son ~200 paquetes y ~80 min en un runner nuevo;
	# con el directorio de salida persistido entre runs, un paquete cuyo .deb
	# ya esta descargado se salta y el run baja a ~15 min, que es lo que
	# lleva el workflow de build-native de kronos3D con sus libs precompiladas.
	#
	# Opt-in y con la clave de cache verificada en el workflow: reutilizar un
	# .deb caducado empacharia el bootstrap con binarios de otro tree, que es
	# justo lo que el gate de com.termux existe para impedir.
	if [ "${TESSL_REUSE_BUILT_DEBS:-0}" = "1" ]; then
		local _existing
		for _existing in "$TERMUX_BUILT_DEBS_DIRECTORY"/*_"$TERMUX_ARCH".deb; do
			[ -f "$_existing" ] || continue
			case "$(basename "$_existing")" in
				"$package_name"_*) echo "[*] Reusing cached '$_existing'"; return 0 ;;
			esac
		done
	fi

	# Build package from source
	# stderr will be redirected to stdout and both will be captured into variable and printed on screen
	cd "$TERMUX_PACKAGES_DIRECTORY"
	echo $'\n\n\n'"[*] Building '$package_name'..."
	exec 99>&1
	build_output="$("$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" -a "$TERMUX_ARCH" "$source_pkg" 2>&1 | tee >(cat - >&99); exit ${PIPESTATUS[0]})";
	return_value=$?
	echo "[*] Building '$package_name' exited with exit code $return_value"
	exec 99>&-
	if [ $return_value -ne 0 ]; then
		echo "Failed to build package '$package_name' for arch '$TERMUX_ARCH'" 1>&2

		# Dependency packages may not have a build.sh, so we ignore the error.
		# A better way should be implemented to validate if its actually a dependency
		# and not a required package itself, by removing dependencies from PACKAGES array.
		if [[ $IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR == "1" ]] && [[ "$build_output" == *"No build.sh script at package dir"* ]]; then
			echo "Ignoring error 'No build.sh script at package dir'" 1>&2
			return 0
		fi
	fi

	return $return_value

}

# Extract *.deb files to the bootstrap root.
extract_debs() {

	local package_arch="$1"
	local current_package_name
	local data_archive
	local control_archive
	local package_tmpdir
	local deb
	local file

	cd "$TERMUX_BUILT_DEBS_DIRECTORY"

	if [ -z "$(ls -A)" ]; then
		echo $'\n\n\n'"No debs found"
		return 1
	else
		echo $'\n\n\n'"Deb Files:"
		echo "\""
		ls
		echo "\""
	fi

	for deb in *.deb; do

		current_package_name="$(echo "$deb" | sed -E 's/^([^_]+).*/\1/' )"
		current_package_arch="$(echo "$deb" | sed -E 's/.*_(aarch64|all|arm|i686|x86_64).deb$/\1/' )"
		echo "current_package_name: '$current_package_name'"
		echo "current_package_arch: '$current_package_arch'"

		if [[ "$current_package_arch" != "$package_arch" ]] && [[ "$current_package_arch" != "all" ]]; then
			echo "[*] Skipping incompatible package '$deb' for target '$package_arch'..."
			continue
		fi

		if [[ "$current_package_name" == *"-static" ]]; then
			echo "[*] Skipping static package '$deb'..."
			continue
		fi

		if [[ " ${EXTRACTED_PACKAGES[*]} " == *" $current_package_name "* ]]; then
			echo "[*] Skipping already extracted package '$current_package_name'..."
			continue
		fi

		EXTRACTED_PACKAGES+=("$current_package_name")

		package_tmpdir="${BOOTSTRAP_PKGDIR}/${current_package_name}"
		mkdir -p "$package_tmpdir"
		rm -rf "$package_tmpdir"/*

		echo "[*] Extracting '$deb'..."
		(cd "$package_tmpdir"
			ar x "$TERMUX_BUILT_DEBS_DIRECTORY/$deb"

			# data.tar may have extension different from .xz
			if [ -f "./data.tar.xz" ]; then
				data_archive="data.tar.xz"
			elif [ -f "./data.tar.gz" ]; then
				data_archive="data.tar.gz"
			else
				echo "No data.tar.* found in '$deb'."
				return 1
			fi

			# Do same for control.tar.
			if [ -f "./control.tar.xz" ]; then
				control_archive="control.tar.xz"
			elif [ -f "./control.tar.gz" ]; then
				control_archive="control.tar.gz"
			else
				echo "No control.tar.* found in '$deb'."
				return 1
			fi

			# Extract files.
			tar xf "$data_archive" -C "$BOOTSTRAP_ROOTFS"

			if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
				# Register extracted files.
				tar tf "$data_archive" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.list"

				# Generate checksums (md5).
				tar xf "$data_archive"
				find data -type f -print0 | xargs -0 -r md5sum | sed 's@^\.$@@g' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.md5sums"

				# Extract metadata.
				tar xf "$control_archive"
				{
					cat control
					echo "Status: install ok installed"
					echo
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"

				# Additional data: conffiles & scripts
				for file in conffiles postinst postrm preinst prerm; do
					if [ -f "${PWD}/${file}" ]; then
						cp "$file" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.${file}"
					fi
				done
			fi
		)
	done

}

# Add termux bootstrap second stage files
add_termux_bootstrap_second_stage_files() {

	local package_arch="$1"

	echo $'\n\n\n'"[*] Adding termux bootstrap second stage files..."

	mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}"
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		-e "s|@TERMUX_PACKAGE_MANAGER@|${TERMUX_PACKAGE_MANAGER}|g" \
		-e "s|@TERMUX_PACKAGE_ARCH@|${package_arch}|g" \
		-e "s|@TERMUX_APP__NAME@|${TERMUX_APP__NAME}|g" \
		-e "s|@TERMUX_ENV__S_TERMUX@|${TERMUX_ENV__S_TERMUX}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"
	chmod 700 "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"

	# TODO: Remove it when Termux app supports `pacman` bootstraps installation.
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX__PREFIX__PROFILE_D_DIR@|${TERMUX__PREFIX__PROFILE_D_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/01-termux-bootstrap-second-stage-fallback.sh" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"
	chmod 600 "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"

}

# FORK PATCH (bootstrap propio): crear el layout de directorios que dpkg, apt y
# ncurses necesitan en tiempo de ejecucion.
#
# El ZIP oficial de Termux los trae ya hechos porque su release se ensambla a
# mano; nosotros montamos el rootfs solo con .deb, asi que los directorios
# vacios no existen. dpkg falla al arrancar si no esta etc/dpkg, y apt escribe
# en var/log/apt y var/lib/dpkg/updates.
#
# Contenido copiado del bootstrap oficial: los directorios van vacios a
# proposito y solo etc/dpkg/dpkg.cfg lleva algo.
create_runtime_directories() {
	local arch="$1"
	local root="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
	local d

	[ -d "$root" ] || return 0

	for d in etc/apt/apt.conf.d etc/apt/preferences.d etc/dpkg etc/dpkg/dpkg.cfg.d \
	         etc/dpkg/origins var/lib/dpkg var/lib/dpkg/info var/lib/dpkg/updates \
	         var/log/apt var/log; do
		mkdir -p "$root/$d"
	done

	# no-debsig: los .deb de Termux no vienen firmados, asi que con la
	# verificacion activada dpkg los rechazaria todos.
	# log: deja rastro en var/log/dpkg.log en vez de solo por stderr.
	if [ ! -f "$root/etc/dpkg/dpkg.cfg" ]; then
		cat > "$root/etc/dpkg/dpkg.cfg" <<-'EOF'
			# dpkg configuration file
			#
			# Termux does not ship embedded package signatures, so debsig
			# verification would reject every package in the archive.
			no-debsig

			# Log status changes and actions to a file.
			log /var/log/dpkg.log
		EOF
	fi

	echo "[*] runtime directory layout created"
	return 0
}

# FORK PATCH (bootstrap propio): gate de validacion. Un bootstrap cuyo ELF
# conserve /data/data/com.termux en .rodata no es reparable en el movil (el
# string es de ancho fijo y el prefijo de la app es mas largo), asi que en
# lugar de empaquetarlo y que falle en tiempo de ejecucion, se aborta aqui.
# Se comprueba el CONTENIDO, no solo los scripts: el bug original estaba
# justamente en strings de ELF (.rodata), no en los ficheros de texto.
# FORK PATCH (bootstrap propio): sustituir /data/data/com.termux por el
# data dir de la app en todo fichero de TEXTO del rootfs.
#
# El prefijo de la app es mas largo que com.termux, asi que esto solo es
# seguro en texto: en un ELF el reemplazo creceria el fichero y dejaria
# corruptos los offsets de las secciones posteriores. Los ELF que contengan la
# ruta se dejan intactos y los reporta validate_bootstrap_rootfs, porque
# arreglar uno exige recompilar el paquete, no editar su binario.
scrub_stock_text_paths() {
	local arch="$1"
	local root="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
	local f n

	[ -d "$root" ] || return 0
	[ "$TERMUX_APP__DATA_DIR" = "/data/data/com.termux" ] && return 0

	n=0
	while IFS= read -r -d '' f; do
		# -I excluye binarios; head descarta los ficheros que son puro ELF.
		head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' && continue
		grep -qI '/data/data/com\.termux' "$f" 2>/dev/null || continue
		sed -i "s|/data/data/com\.termux|${TERMUX_APP__DATA_DIR}|g" "$f" && n=$((n + 1))
	done < <(find "$root" -type f -print0)

	echo "[*] scrubbed stock paths in $n text file(s)"
	return 0
}

validate_bootstrap_rootfs() {
	local arch="$1"
	local root="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
	local bad_files=0
	local hits_file

	echo $'\n\n\n'"[*] Validating '$root' (arch='$arch')'..."

	# 1) Ningun ELF ni script puede contener la ruta del runtime de Termux.
	#    strings solo sobre ELF; los ficheros de texto se buscan aparte.
	hits_file="${BOOTSTRAP_TMPDIR}/stock-refs-${arch}.txt"
	: > "$hits_file"
	local f
	while IFS= read -r -d '' f; do
		if head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF'; then
			strings -a "$f" 2>/dev/null | grep -q '/data/data/com\.termux' \
				&& echo "ELF   $f" >> "$hits_file"
		else
			grep -lI '/data/data/com\.termux' "$f" 2>/dev/null >> "$hits_file" \
				|| true
		fi
	done < <(find "$root" -type f -print0)

	# grep -c imprime "0" Y sale con codigo 1 cuando no hay coincidencias, asi
	# que un `|| echo 0` anadiria un segundo 0 y la comparacion siguiente
	# recibiria "0\n0", fallando en silencio: el gate pasaria siempre. Con
	# `|| true` se conserva el 0 que grep ya imprimio.
	bad_files=$(grep -c . "$hits_file" 2>/dev/null || true)
	bad_files=${bad_files:-0}
	if [ "$bad_files" -gt 0 ] 2>/dev/null; then
		echo "[!] FAIL: $bad_files file(s) still reference /data/data/com.termux"
		echo "[!] first offenders:"
		grep -m 25 . "$hits_file" | sed 's/^/      /'
		echo "[!] the full list is in $hits_file"
		return 1
	fi
	echo "[*] OK: no file references /data/data/com.termux"

	# 2) El prefijo propio debe estar presente en los binarios criticos. Sin
	#    esto, un cierre vacio o todo stock passesarian el punto 1.
	local missing=0 t
	for t in bin/bash bin/sh bin/dpkg bin/apt bin/curl bin/tar \
	         bin/gzip bin/gpg bin/gpgv bin/openssl; do
		if [ -e "$root/$t" ]; then
			if ! strings -a "$root/$t" 2>/dev/null | grep -q "$TERMUX_PREFIX"; then
				echo "[!] WARN: $t does not carry $TERMUX_PREFIX"
				missing=$((missing+1))
			fi
		fi
	done
	if [ "$missing" -gt 0 ]; then
		echo "[!] FAIL: $missing critical binary/binaries lack our prefix"
		return 1
	fi
	echo "[*] OK: critical binaries carry $TERMUX_PREFIX"

	# 3) Estructura de directorios que dpkg/apt/ncurses necesitan en tiempo de
	#    ejecucion y que el simple unzip del APK no crea.
	local d
	for d in etc/apt/apt.conf.d etc/apt/preferences.d etc/dpkg \
	         var/lib/dpkg var/lib/dpkg/info var/lib/dpkg/updates var/log/apt; do
		if [ ! -d "$root/$d" ]; then
			echo "[!] FAIL: missing runtime directory $d"
			return 1
		fi
	done
	if [ ! -f "$root/etc/tls/cert.pem" ] && [ ! -f "$root/etc/tls/ca-certificates.crt" ]; then
		echo "[!] FAIL: no CA bundle in etc/tls"
		return 1
	fi
	echo "[*] OK: runtime directory layout present"
	return 0
}

# Final stage: generate bootstrap archive and place it to current
# working directory.
# Information about symlinks is stored in file SYMLINKS.txt.
create_bootstrap_archive() {

	echo $'\n\n\n'"[*] Creating 'bootstrap-${1}.zip'..."
	(cd "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
		# Do not store symlinks in bootstrap archive.
		# Instead, put all information to SYMLINKS.txt
		while read -r -d '' link; do
			echo "$(readlink "$link")←${link}" >> SYMLINKS.txt
			rm -f "$link"
		done < <(find . -type l -print0)

		zip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./*
	)

	mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "$TERMUX_PACKAGES_DIRECTORY/"

	echo "[*] Finished successfully (${1})."

}

set_build_bootstrap_traps() {

	#set traps for the build_bootstrap_trap itself
	trap 'build_bootstrap_trap' EXIT
	trap 'build_bootstrap_trap TERM' TERM
	trap 'build_bootstrap_trap INT' INT
	trap 'build_bootstrap_trap HUP' HUP
	trap 'build_bootstrap_trap QUIT' QUIT

	return 0

}

build_bootstrap_trap() {

	local build_bootstrap_trap_exit_code=$?
	trap - EXIT

	[ -h "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] && rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY"
	[ -d "$BOOTSTRAP_TMPDIR" ] && rm -rf "$BOOTSTRAP_TMPDIR"

	[ -n "$1" ] && trap - "$1"; exit $build_bootstrap_trap_exit_code

}

show_usage() {

    cat <<'HELP_EOF'

build-bootstraps.sh is a script to build bootstrap archives for the
termux-app from local package sources instead of debs published in
apt repo like done by generate-bootstrap.sh. It allows bootstrap archives
to be easily built for (forked) termux apps without having to publish
an apt repo first.


Usage:
  build-bootstraps.sh [command_options]


Available command_options:
  [ -h  | --help ]             Display this help screen
  [ -f ]             Force build even if packages have already been built.
  [ --android10 ]
                     Generate bootstrap archives for Android 10+ for
                     apk packaging system.
  [ -a | --add <packages> ]
                     Additional packages to include into bootstrap archive.
                     Multiple packages should be passed as comma-separated list.
  [ --architectures <architectures> ]
                     Override default list of architectures for which bootstrap
                     archives will be created. Multiple architectures should be
                     passed as comma-separated list.


The package name/prefix that the bootstrap is built for is defined by
TERMUX_APP_PACKAGE in 'scrips/properties.sh'. It defaults to 'com.termux'.
If package name is changed, make sure to run
`./scripts/run-docker.sh ./clean.sh` or pass '-f' to force rebuild of packages.

### Examples

Build default bootstrap archives for all supported archs:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh &> build.log

Build default bootstrap archive for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 &> build.log

Build bootstrap archive with additionall openssh package for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 --add openssh &> build.log
HELP_EOF

echo $'\n'"TERMUX_APP_PACKAGE: \"$TERMUX_APP_PACKAGE\""
echo "TERMUX_PREFIX: \"${TERMUX_PREFIX[*]}\""
echo "TERMUX_ARCHITECTURES: \"${TERMUX_ARCHITECTURES[*]}\""

}

main() {

	local return_value

	while (($# > 0)); do
		case "$1" in
			-h|--help)
				show_usage
				return 0
				;;
			--android10)
				BOOTSTRAP_ANDROID10_COMPATIBLE=true
				;;
			-a|--add)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					for pkg in $(echo "$2" | tr ',' ' '); do
						ADDITIONAL_PACKAGES+=("$pkg")
					done
					unset pkg
					shift 1
				else
					echo "[!] Option '--add' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			--architectures)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					TERMUX_ARCHITECTURES=()
					for arch in $(echo "$2" | tr ',' ' '); do
						TERMUX_ARCHITECTURES+=("$arch")
					done
					unset arch
					shift 1
				else
					echo "[!] Option '--architectures' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			-f)
				BUILD_PACKAGE_OPTIONS+=("-f")
				FORCE_BUILD_PACKAGES=1
				;;
			*)
				echo "[!] Got unknown option '$1'" 1>&2
				show_usage
				return 1
				;;
		esac
		shift 1
	done

	set_build_bootstrap_traps

	for TERMUX_ARCH in "${TERMUX_ARCHITECTURES[@]}"; do
		if [[ " ${TERMUX_DEFAULT_ARCHITECTURES[*]} " != *" $TERMUX_ARCH "* ]]; then
			echo "Unsupported architecture '$TERMUX_ARCH' for in architectures list: '${TERMUX_ARCHITECTURES[*]}'" 1>&2
			echo "Supported architectures: '${TERMUX_DEFAULT_ARCHITECTURES[*]}'" 1>&2
			return 1
		fi
	done

	for TERMUX_ARCH in "${TERMUX_ARCHITECTURES[@]}"; do
		termux_step_handle_buildarch

		if [[ $FORCE_BUILD_PACKAGES == "1" ]]; then
			rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY_FOR_ARCH"/*
			rm -f "$TERMUX_BUILT_DEBS_DIRECTORY"/*
		fi

		BOOTSTRAP_ROOTFS="$BOOTSTRAP_TMPDIR/rootfs-${TERMUX_ARCH}"
		BOOTSTRAP_PKGDIR="$BOOTSTRAP_TMPDIR/packages-${TERMUX_ARCH}"

		# Create initial directories for $TERMUX_PREFIX
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/apt.conf.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/preferences.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/triggers"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/updates"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log/apt"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/available"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
		fi
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/tmp"



		PACKAGES=()
		EXTRACTED_PACKAGES=()

		# Package manager.
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			PACKAGES+=("apt")
		fi

		# Core utilities.
		PACKAGES+=("bash") # Used by `termux-bootstrap-second-stage.sh`
		PACKAGES+=("bzip2")
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			PACKAGES+=("command-not-found")
		else
			PACKAGES+=("proot")
		fi
		PACKAGES+=("coreutils")
		PACKAGES+=("dash")
		PACKAGES+=("diffutils")
		PACKAGES+=("findutils")
		PACKAGES+=("gawk")
		PACKAGES+=("grep")
		PACKAGES+=("gzip")
		PACKAGES+=("less")
		PACKAGES+=("procps")
		PACKAGES+=("psmisc")
		PACKAGES+=("sed")
		PACKAGES+=("tar")
		PACKAGES+=("termux-core")
		PACKAGES+=("termux-exec")
		PACKAGES+=("termux-keyring")
		PACKAGES+=("termux-tools")
		PACKAGES+=("util-linux")

		# Additional.
		PACKAGES+=("ed")
		PACKAGES+=("debianutils")
		PACKAGES+=("dos2unix")
		PACKAGES+=("inetutils")
		PACKAGES+=("lsof")
		PACKAGES+=("nano")
		PACKAGES+=("net-tools")
		PACKAGES+=("patch")
		PACKAGES+=("unzip")

		# Handle additional packages.
		for add_pkg in "${ADDITIONAL_PACKAGES[@]}"; do
			if [[ " ${PACKAGES[*]} " != *" $add_pkg "* ]]; then
				PACKAGES+=("$add_pkg")
			fi
		done
		unset add_pkg

		# Build packages.
		for package_name in "${PACKAGES[@]}"; do
			set +e
			build_package "$TERMUX_ARCH" "$package_name" || return $?
			set -e
		done

		# Extract all debs.
		extract_debs "$TERMUX_ARCH" || return $?

		# Add termux bootstrap second stage files
		add_termux_bootstrap_second_stage_files "$package_arch"

		# FORK PATCH: layout de directorios de runtime. Va antes del scrub para
		# que el dpkg.cfg recien creado pase tambien por la sustitucion, y antes
		# del gate para que lo valide como cualquier otro fichero del rootfs.
		create_runtime_directories "$TERMUX_ARCH" || return $?

		# FORK PATCH (bootstrap propio): reescribir primero, validar despues.
		scrub_stock_text_paths "$TERMUX_ARCH" || return $?

		# Abortar aqui y no en el movil si aun queda alguna ruta de Termux.
		validate_bootstrap_rootfs "$TERMUX_ARCH" || return $?

		# Create bootstrap archive.
		create_bootstrap_archive "$TERMUX_ARCH" || return $?

	done

}

main "$@"

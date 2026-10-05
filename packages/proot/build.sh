# Contributor: @michalbednarski
TERMUX_PKG_HOMEPAGE=https://proot-me.github.io/
TERMUX_PKG_DESCRIPTION="Emulate chroot, bind mount and binfmt_misc for non-root users"
TERMUX_PKG_LICENSE=GPL-2.0
TERMUX_PKG_MAINTAINER="Michal Bednarski <michal.bednarski@gmail.com>"
TERMUX_PKG_VERSION=5.1.107.96
TERMUX_PKG_SRCURL=https://github.com/termux/proot/archive/v${TERMUX_PKG_VERSION}.zip
TERMUX_PKG_SHA256=75f654fe60dea92dabff2bf083ae8bfe4f91baa6a1a374786a6bf391015eebaa
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_TAG_TYPE="newest-tag"
TERMUX_PKG_DEPENDS="libandroid-shmem, libtalloc"
TERMUX_PKG_SUGGESTS="proot-distro"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_MAKE_ARGS="-C src PROOT_WITH_LIBANDROID_SHMEM=true"

# Install loader in libexec instead of extracting it every time
export PROOT_UNBUNDLE_LOADER=$TERMUX_PREFIX/libexec/proot

termux_step_pre_configure() {
	CPPFLAGS+=" -DARG_MAX=131072 -DVERSION=\\\"${TERMUX_PKG_VERSION}\\\""

	# FORK PATCH: proot's source hardcodes Termux' data dir inside a diagnostic
	# message in src/cli/cli.c:
	#
	#   "It seems that termux-exec is active and is preloading
	#    /data/data/com.termux/... to executable paths"
	#
	# The string is only ever printed, never resolved by proot, so the binary
	# works either way. It still lands in .rodata, and the bootstrap gate in
	# scripts/build-bootstraps.sh refuses to ship any ELF that references
	# /data/data/com.termux.
	#
	# Patching the SOURCE is the only safe option. The replacement is longer
	# than com.termux, so a sed on the finished ELF would grow the file and
	# shift every section offset after it, producing a corrupt binary. Letting
	# the compiler embed the C string makes the length correct by construction.
	#
	# This lives in termux_step_pre_configure rather than a post-unpack hook
	# because this tree of termux-packages defines no
	# termux_step_post_unpack_source, so such a hook is never called at all and
	# proot shipped unpatched. Measured in run 37237221477: the central text
	# scrub cleaned 6 files and bin/proot was the only one left.
	[ "$TERMUX_APP__DATA_DIR" = "/data/data/com.termux" ] && return 0

	local _f _n=0
	while IFS= read -r -d '' _f; do
		head -c 4 "$_f" 2>/dev/null | grep -q $'\x7fELF' && continue
		sed -i "s|/data/data/com\.termux|${TERMUX_APP__DATA_DIR}|g" "$_f"
		_n=$((_n + 1))
	done < <(find "$TERMUX_PKG_SRCDIR" -type f -print0)
	echo "[*] proot: rewrote stock data dir in $_n source file(s)"
}

termux_step_post_make_install() {
	mkdir -p $TERMUX_PREFIX/share/man/man1
	install -m600 $TERMUX_PKG_SRCDIR/doc/proot/man.1 $TERMUX_PREFIX/share/man/man1/proot.1

	sed -e "s|@TERMUX_PREFIX@|$TERMUX_PREFIX|g" \
		$TERMUX_PKG_BUILDER_DIR/termux-chroot \
		> $TERMUX_PREFIX/bin/termux-chroot
	chmod 700 $TERMUX_PREFIX/bin/termux-chroot
}
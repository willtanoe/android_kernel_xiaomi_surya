#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

readonly KERNEL_PATH="out/arch/arm64/boot"
readonly DEFCONFIG="arch/arm64/configs/surya_defconfig"
readonly CLANG_ARCHIVE="clang-13289611-linux-x86.tar.xz"
readonly CLANG_URL="https://github.com/Impqxr/aosp_clang_ci/releases/download/13289611/${CLANG_ARCHIVE}"
readonly CLANG_SHA256="0a1fbf7f990122a63a2f8b9d6ddce458bebfb1bbe1c9efe8f1b58a2a3814ae7c"
readonly ANYKERNEL_URL="https://github.com/kylieeXD/AK3-Surya.git"
readonly ANYKERNEL_BRANCH="staging"
readonly ANYKERNEL_COMMIT="b5ce992ec2e2f85eaa3b0724fd6b63d8e4dc1352"

ROOT_VARIANT="${1:-}"
BUILD_DATE="${2:-$(TZ=Asia/Jakarta date +%Y%m%d%H%M)}"
ARTIFACT_DIR="${3:-${PWD}/artifacts}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc --all)}"

case "${ROOT_VARIANT}" in
	KSU | NoKSU) ;;
	*)
		echo "Usage: $0 <KSU|NoKSU> [build-date] [artifact-directory]" >&2
		exit 2
		;;
esac

mkdir -p "${ARTIFACT_DIR}"
ARTIFACT_DIR="$(realpath "${ARTIFACT_DIR}")"
readonly KERNEL_NAME="rethinking-${ROOT_VARIANT}-${BUILD_DATE}.zip"
readonly OUTPUT_ZIP="${ARTIFACT_DIR}/${KERNEL_NAME}"

setup_toolchain() {
	if [[ -x clang/bin/clang ]]; then
		return
	fi

	wget -c "${CLANG_URL}" -O "${CLANG_ARCHIVE}"
	printf '%s  %s\n' "${CLANG_SHA256}" "${CLANG_ARCHIVE}" | sha256sum --check --strict

	rm -rf clang.extract
	mkdir -p clang clang.extract
	tar -xf "${CLANG_ARCHIVE}" -C clang.extract
	if compgen -G 'clang.extract/clang-*' >/dev/null; then
		cp -a clang.extract/clang-*/. clang/
	else
		cp -a clang.extract/. clang/
	fi
	rm -rf clang.extract
}

configure_kernel() {
	rm -rf out
	mkdir -p out

	make O=out ARCH=arm64 surya_defconfig
	if [[ "${ROOT_VARIANT}" == "KSU" ]]; then
		scripts/config --file out/.config --enable KSU
	else
		scripts/config --file out/.config --disable KSU
	fi
	make O=out ARCH=arm64 olddefconfig
}

compile_kernel() {
	export PATH="${PWD}/clang/bin:${PATH}"
	export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.cache/ccache}"
	export KBUILD_BUILD_HOST="builder"
	export KBUILD_BUILD_USER="willtanoe"
	export KBUILD_BUILD_VERSION=1
	export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
	export KBUILD_BUILD_TIMESTAMP="$(git show -s --format=%cD HEAD)"

	ccache --max-size "${CCACHE_MAXSIZE:-10G}"
	configure_kernel
	make -j"${BUILD_JOBS}" O=out ARCH=arm64 \
		CC="ccache clang" LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
		OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
		CROSS_COMPILE=aarch64-linux-gnu- \
		CROSS_COMPILE_COMPAT=arm-linux-gnueabi- LLVM=1 LLVM_IAS=1
}

package_kernel() {
	local file
	for file in Image Image.gz dtb.img dtbo.img; do
		if [[ ! -f "${KERNEL_PATH}/${file}" ]]; then
			echo "Missing kernel output: ${KERNEL_PATH}/${file}" >&2
			exit 1
		fi
	done

	rm -rf out/anykernel
	git clone --quiet --filter=blob:none --single-branch \
		--branch "${ANYKERNEL_BRANCH}" "${ANYKERNEL_URL}" out/anykernel
	if [[ "$(git -C out/anykernel rev-parse HEAD)" != "${ANYKERNEL_COMMIT}" ]]; then
		echo "AnyKernel branch moved; update the pinned commit after review" >&2
		exit 1
	fi

	cp "${KERNEL_PATH}/dtb.img" out/anykernel/kernels/
	cp "${KERNEL_PATH}/dtbo.img" out/anykernel/kernels/
	cp "${KERNEL_PATH}/Image.gz" out/anykernel/kernels/
	rm -rf out/anykernel/.git
	rm -f "${OUTPUT_ZIP}"
	(
		cd out/anykernel
		zip -qr9 "${OUTPUT_ZIP}" .
	)
}

main() {
	setup_toolchain
	compile_kernel
	package_kernel

	sha256sum "${OUTPUT_ZIP}"
	ccache --show-stats
	echo "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)"
}

rm -f compile.log
main 2>&1 | tee compile.log

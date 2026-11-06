#!/bin/bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
cd /root/kernel3
export PATH=/root/toolchain/clang-r383902b1/bin:$PATH
make O=out ARCH=arm64 \
  CC=clang LLVM=1 LLVM_IAS=1 \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  -j14 Image 2>&1 | grep -E 'error:|Error [0-9]|^\s+(LD|OBJCOPY|GEN)|BUILD_EXIT'
echo "K3SUKI_BUILD_EXIT=${PIPESTATUS[0]}"
ls -l out/arch/arm64/boot/Image
echo "K3SUKI_DONE"

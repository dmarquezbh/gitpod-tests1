#!/usr/bin/env bash
# Builds the Zero C# server with bflat and links libpq. The SDK's native step
# cannot pass extra ldflags, so this mirrors its command line (payload refs and
# zerocore.o) and adds -L/-lpq/-rpath.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ZERO_SDK:-$HOME/.nuget/packages/zerocsharp.sdk/0.3.0}"
BF="${ZERO_BFLAT:-$HOME/.nuget/packages/zerocsharp.bflat.linux-x64/0.3.0/tools/bflat/bflat}"
PG="${PG_PREFIX:-$HOME/.local/opt/pgdev}/usr/lib/x86_64-linux-gnu"
"$BF" build Program.cs \
  -r "$SDK/payload/ref/System.Private.CoreLib.dll" \
  -r "$SDK/payload/ref/BflatLib.dll" \
  --stdlib:none --no-reflection --langversion preview \
  -i libc -i libm.so.6 -i libpq.so.5 \
  --os linux --arch x64 \
  --ldflags "$SDK/payload/native/linux-x64/zerocore.o" \
  --ldflags "-z nostart-stop-gc" \
  --ldflags "-L$PG -lpq -rpath $PG" \
  -o bench

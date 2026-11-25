"""Build the self-contained Windows desktop executable from the shared archive resources."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
VERSION = "1.0.3537.50"
DIGEST = "5ea526bbd728adda0da4d31219267e96460494a427e4894c4e09d9f320f4b9aa"
PACKAGE = f"microsoft.web.webview2.{VERSION}.nupkg"
URL = f"https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/{VERSION}/{PACKAGE}"
DLLS = ["Microsoft.Web.WebView2.Core", "Microsoft.Web.WebView2.WinForms"]
REFERENCES = ["System", "System.Core", "System.Drawing", "System.Windows.Forms", "System.Web.Extensions",
              "System.Net.Http", "System.Security", "System.IO.Compression",
              "System.Xml", "System.Xml.Linq", "Microsoft.VisualBasic"]

def sdk_package(supplied):
    bundled = ROOT / "Dependencies" / PACKAGE
    if supplied or bundled.is_file():
        package = supplied or bundled
    else:
        cache = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir())) / "Tool Drive Offline" / "BuildDependencies"
        cache.mkdir(parents=True, exist_ok=True)
        package = cache / PACKAGE
        if not package.exists():
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as handle:
                incoming = Path(handle.name)
            try:
                urllib.request.urlretrieve(URL, incoming)
                if hashlib.sha256(incoming.read_bytes()).hexdigest() != DIGEST:
                    raise ValueError("Microsoft WebView2 package failed its checksum")
                os.replace(incoming, package)
            finally:
                incoming.unlink(missing_ok=True)
    if hashlib.sha256(package.read_bytes()).hexdigest() != DIGEST:
        raise ValueError("Microsoft WebView2 package failed its checksum: " + str(package))
    return package

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, help="Path to the pinned WebView2 NuGet package")
    parser.add_argument("--output", type=Path, default=HERE / "dist")
    parser.add_argument("--compiler", type=Path, help="C# compiler, optionally Roslyn csc.dll for cross-compilation")
    parser.add_argument("--references", type=Path, help=".NET Framework 4.8 reference assemblies")
    args = parser.parse_args()
    compiler = args.compiler
    if not compiler:
        windows = Path(os.environ["WINDIR"]) / "Microsoft.NET"
        compiler = next((p for d in ("Framework64", "Framework") for p in [windows / d / "v4.0.30319/csc.exe"] if p.is_file()), None)
        if not compiler:
            raise SystemExit("Install .NET Framework 4.8 or specify a C# compiler")
    compiler_command = [str(compiler)]
    if compiler.suffix == ".dll":
        compiler_command.insert(0, os.environ.get("DOTNET_HOST_PATH", "dotnet"))
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        site = stage / "site"
        site.mkdir()
        subprocess.run([sys.executable, str(ROOT / "macOS App/prepare-resources.py"), str(ROOT), str(site), "--windows"], check=True)
        exe = stage / "Tool Drive Offline.exe"
        flags = ["/nologo", "/target:winexe", "/platform:anycpu", "/optimize+", "/langversion:5",
                 "/warn:4", "/codepage:65001", "/out:" + str(exe), "/win32icon:" + str(HERE / "Icons/multicolor.ico"),
                 "/win32manifest:" + str(HERE / "app.manifest"), "/resource:" + str(ROOT / "catalog.json") + ",ToolDriveOffline.catalog.json"]
        with zipfile.ZipFile(sdk_package(args.sdk)) as sdk:
            for name in DLLS:
                dll = stage / (name + ".dll")
                dll.write_bytes(sdk.read("lib/net462/" + dll.name))
                flags.extend(["/reference:" + str(dll), "/resource:" + str(dll) + ",Desktop." + dll.name])
            for arch in ("x86", "x64", "arm64"):
                dll = stage / (arch + ".WebView2Loader.dll")
                dll.write_bytes(sdk.read(f"runtimes/win-{arch}/native/WebView2Loader.dll"))
                flags.append("/resource:" + str(dll) + ",Desktop." + dll.name)
            (site / "Microsoft-WebView2-LICENSE.txt").write_bytes(sdk.read("LICENSE.txt"))
            (site / "Microsoft-WebView2-NOTICE.txt").write_bytes(sdk.read("NOTICE.txt"))
        for arch in ("x86", "x64"):
            name = f"Lossless-{arch}.exe"
            flags.append("/resource:" + str(HERE / "Codecs" / name) + ",Desktop." + name)
        for filename in ("COPYING.LGPLv2.1", "ThirdParty.txt"):
            shutil.copyfile(HERE / "Codecs" / filename, site / filename)
        archive = stage / "site.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as web:
            for f in sorted(site.rglob("*")):
                if f.is_file() and f.name != ".DS_Store":
                    web.write(f, f.relative_to(site).as_posix())
        flags.append("/resource:" + str(archive) + ",Desktop.site.zip")
        if args.references:
            flags.extend(["/nostdlib+", "/reference:" + str(args.references / "mscorlib.dll")])
        for name in REFERENCES:
            dll = Path(name + ".dll")
            flags.append("/reference:" + str(args.references / dll if args.references else dll))
        sources = [p for p in sorted(HERE.glob("*.cs")) if not p.stem.endswith("Checks")]
        subprocess.run(compiler_command + flags + [str(p) for p in sources], check=True)
        shutil.copy2(exe, args.output / exe.name)
        shutil.copy2(HERE / "READ ME.txt", args.output)
        print(args.output / exe.name)

if __name__ == "__main__":
    main()

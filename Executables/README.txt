================================================================
  Chamber — Executables Folder
================================================================

Place the following installers in this folder BEFORE packaging
the playbook into .apbx format:

1. DirectX End-User Runtime
   - Download from Microsoft:
     https://www.microsoft.com/en-us/download/details.aspx?id=35
   - Extract the downloaded package
   - Place the extracted folder here as: DirectX/DXSETUP.exe
   - Final path: Executables/DirectX/DXSETUP.exe

2. Visual C++ Redistributables All-in-One (optional)
   - Download the "Visual C++ Redistributable Runtimes All-in-One"
     package (covers 2005, 2008, 2010, 2012, 2013, 2015-2022)
   - Rename or repackage as: vcredist_all.exe
   - Final path: Executables/vcredist_all.exe
   - Only needed for the legacy 2005-2013 runtimes. The 2015-2022
     runtimes (x64 + x86) are always installed by
     Install-VCRedist.ps1 - see VCRedist/ below.

3. Visual C++ 2015-2022 runtimes (VCRedist/)
   - The release build downloads these automatically. For a local
     build, download them yourself:
       https://aka.ms/vc14/vc_redist.x64.exe
       https://aka.ms/vc14/vc_redist.x86.exe
   - Final paths: Executables/VCRedist/VC_redist.x64.exe
                  Executables/VCRedist/VC_redist.x86.exe
   - Bundled so the runtimes install with no network, e.g. during
     an ISO install on a PC whose Wi-Fi driver is missing. Without
     them the script downloads at run time instead.

IMPORTANT: If these files are not present, the playbook will
skip their installation and continue normally. Game launchers
and optional tools are installed via winget and do NOT need
to be placed here.

================================================================

================================================================
  Browsers/ — cached ISO payloads (do not populate by hand)
================================================================

During ISO injection, Configuration/Tasks/0-iso-cache.yml has AME
download the selected browser installer into:

    Executables/Browsers/

That happens on the machine building the ISO, and the file ends up
inside the image. At first boot, Install-CachedBrowser.ps1 checks
the file is present and carries a valid Authenticode signature from
the expected vendor, then installs it silently — so an injected
install needs no internet for the browser.

Nothing goes in this folder in source control, and nothing needs to
be placed here before packaging. It is git-ignored, AME creates it,
and a traditional (drag-and-drop) run never uses it — that path
still installs the browser through winget.

If the cached file is missing, truncated, or signed by anyone other
than the expected vendor, the install is SKIPPED rather than
attempted. The outcome is written to the Chamber deployment receipt
at C:\ChamberTech\deployment-receipt.json, and Chamber Verify
reports it. Edge remains available either way.

================================================================

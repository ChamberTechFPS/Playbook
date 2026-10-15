================================================================
  Chamber - OOBE Software Icons
================================================================

AME resolves every <Software><Package><Icon> in playbook.conf from
this folder. If the folder or a named file is missing, AME throws
while building the OOBE software list, so both files must ship
inside Chamber.apbx.

  chrome.png    Google Chrome tile
  brave.png     Brave tile

------------------------------------------------------------------
PLACEHOLDERS - NOT THE VENDOR MARKS
------------------------------------------------------------------

Both files are currently neutral Chamber-purple placeholders, not
Google or Brave logos.

PRD FR-024 asks for clear vendor marks, and PRD open question 8 -
"Are Chrome and Brave icon assets licensed for redistribution
inside Chamber.apbx?" - is still open. Chamber.apbx is a
redistributed archive under CC BY-NC-SA, so shipping a vendor
trademark inside it is a licensing decision, not a design one.
Placeholders keep the OOBE rendering correctly and keep the
question honest until it is answered.

To replace them once redistribution is confirmed:

  1. Take the mark from the vendor's own brand page:
       Google  - https://about.google/brand-resource-center/
       Brave   - https://brave.com/brand/
  2. Export 128x128 PNG, transparent background, centred with a
     little padding so AME's tile does not clip it.
  3. Keep the file names exactly as above - playbook.conf and
     tools/validate_playbook_conf.py both match on them.
  4. Re-run tools/generate_verification_manifest.py is NOT needed;
     icons are not part of the verification manifest.

================================================================

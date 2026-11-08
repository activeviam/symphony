# Retired Shared publication

The ActiveViam Shared Symphony pilot is being retired at Michael's request.
`publish-shared.yml` is retained here for reference, outside GitHub's active
workflow directory. Successful main CI no longer dispatches publication, and
manual publication is unavailable after merge. Source CI remains unchanged.

Merge this change before shared-infrastructure PR 43, which removes the private
publisher, Symphony Application and remaining legacy runners. Workload removal
and live verification happen in that repository; this source change alone does
not stop the deployed service. Do not restore the publisher without a reviewed
runner, registry and deployment decision. Credentials are not revoked here.

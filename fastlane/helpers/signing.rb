# extra_bundles: array of [bundle_id, target_name] pairs.
# Built from the deploy lane's extra_bundle_ids option, which is a space-separated
# list of "bundle_id=target_name" strings (e.g. "net.dinglebox.cabinetdoor.Clip=epac-clip").
# Apps without extensions pass extra_bundle_ids:"" and extra_bundles becomes [].
def bake_manual_signing(xcodeproj:, team_id:, primary_target:, primary_bundle:, extra_bundles:, api_key:)
  all_bundles = [[primary_bundle, primary_target]] + extra_bundles

  all_bundles.each do |bundle_id, target_name|
    profile_uuid = sigh(
      api_key:        api_key,
      app_identifier: bundle_id,
      force:          false
    )

    update_code_signing_settings(
      use_automatic_signing: false,
      path:                  xcodeproj,
      team_id:               team_id,
      targets:               [target_name],
      code_sign_identity:    "Apple Distribution",
      profile_uuid:          profile_uuid
    )
  end
end

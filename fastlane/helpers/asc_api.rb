def asc_api_key
  app_store_connect_api_key(
    key_id:       ENV.fetch("ASC_KEY_ID"),
    issuer_id:    ENV.fetch("ASC_ISSUER_ID"),
    key_filepath: File.expand_path(
      "~/.appstoreconnect/private_keys/AuthKey_#{ENV.fetch('ASC_KEY_ID')}.p8"
    ),
    duration:  1200,
    in_house:  false
  )
end

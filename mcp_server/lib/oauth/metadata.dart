const oauthScope = 'gym';

String protectedResourceMetadataUrl(String issuer) =>
    '$issuer/.well-known/oauth-protected-resource/mcp';

Map<String, Object?> protectedResourceMetadata({
  required String issuer,
  required String resource,
}) => {
  'resource': resource,
  'authorization_servers': [issuer],
  'scopes_supported': [oauthScope],
  'bearer_methods_supported': ['header'],
};

Map<String, Object?> authorizationServerMetadata(String issuer) => {
  'issuer': issuer,
  'authorization_endpoint': '$issuer/authorize',
  'token_endpoint': '$issuer/token',
  'response_types_supported': ['code'],
  'grant_types_supported': ['authorization_code', 'refresh_token'],
  'token_endpoint_auth_methods_supported': ['none'],
  'code_challenge_methods_supported': ['S256'],
  'scopes_supported': [oauthScope],
  'client_id_metadata_document_supported': true,
  'authorization_response_iss_parameter_supported': true,
};

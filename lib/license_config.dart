/// Subscription / licensing backend (your Firebase project).
///
/// Leave the placeholders as they are and the app runs with NO licence checks (useful for your own use or testing).
/// To enable subscriptions, put your Firebase project ID and Web API key here (or pass
/// --dart-define=LICENSE_PROJECT=... --dart-define=LICENSE_API_KEY=... when building), then use the Kibo Admin app
/// to manage subscribers. Anonymous sign-in must be enabled in Firebase Authentication.
const licenseProject = String.fromEnvironment('LICENSE_PROJECT', defaultValue: 'inventory-9892f');
const licenseApiKey = String.fromEnvironment('LICENSE_API_KEY', defaultValue: 'AIzaSyDUtatIHmCx_lqr5bbcYmBKIB9ekP_Gl_s');
const appVersion = '1.0.0';

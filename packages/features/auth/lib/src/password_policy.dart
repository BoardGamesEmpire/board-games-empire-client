/// The client's **registration** password policy (#187).
///
/// ## Why this is a registration rule only
///
/// At sign-in the server is the only authority on whether a credential is
/// valid, so the sign-in form deliberately does **not** enforce a length
/// minimum — it validates `required` and nothing more. BGE is self-hosted:
/// an account created under a shorter minimum, under an older policy, or
/// provisioned by an admin is a legal account, and a client-side length
/// check would reject the correct password before the server ever saw it,
/// with a "too short" message that reads as "your correct password is
/// wrong". That is a hard lockout the hoster cannot clear.
///
/// This constant exists in one place so registration has a single home for
/// it, and so the reasoning above sits next to the value rather than in a
/// commit message. **Do not reference it from `LoginForm`.**
///
/// BetterAuth's own default minimum happens to be 8, which is why the old
/// sign-in check never visibly bit. If server capability discovery (#36)
/// ever advertises a password policy, registration should source the value
/// from there instead of from this constant.
const int kMinRegistrationPasswordLength = 8;

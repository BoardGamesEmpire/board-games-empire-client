# profile

"Your profile" (#547): the signed-in user reads their own profile on the
active server, edits it, and chooses its reach and whether search finds
them.

## Nothing is cached

The profile is read whenever the screen opens, and every save goes straight
to the server. There is no drift table or web store. Offline, Save is
disabled and says why, and the fields are read-only.

## Shape

- `ProfileBloc`: reads the profile, then saves one patch at a time. A read
  asked for while another is out replaces it, so only the last one lands. A
  second Save while one is out sends nothing. A save that lands takes the
  server's answer as the profile, so the form shows what was stored: the
  server trims text and sanitizes the bio. A failed save says why until the
  next edit, and so does a save that landed.
- `ProfileScreen`: the page. Loading; a failed read and a profile the server
  doesn't have yet, each with Try again, which keeps focus on the title; then
  the avatar, name and `@username`, read-only, above the form.
- `ProfileForm`: the fields, in five headed groups (About you, Playing,
  Practical details, Who can see your profile, Search), with Save at the
  end. Save sends only what changed, and is disabled until something has. A
  field left as stored isn't sent, so it is never checked against its cap.
  The form owns its `FormGroup`, and takes a new profile's values whenever
  it is handed a new `initial`, so its parent doesn't key it.
- `profilePatchOf`: the diff behind Save. Text is compared and sent trimmed,
  as the server trims it, apart from the bio, which is Markdown: its leading
  spaces can be structure, so it is kept as typed. Lengths are measured as
  the server measures them, by `serverStringLength`.

The remote is `UserProfileRemoteDataSource` in `network_interface`.

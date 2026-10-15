# Changelog

## 0.1.0 (unreleased)

- First version: Vine 2.5.1 shows diVine's content. Guest sign-in (any e-mail and password), home (the most engaging
  classic Vines), popular, profiles with the original Vine colours, user posts, followers/following, comments, likes
  and revines lists, hashtags, search, channels (Classic Vines, New on diVine, diVine's categories) and the Explore
  page.
- Archived Vines whose video is missing on diVine are left out of the feeds.
- Actions that need an account (like, comment, follow, revine, post) are refused with a message.
- Conflicts with VineRedirect (bag.xml.vineredirect): it rewrites Vine's addresses to an unset server, which broke
  every feed and the Explore page.
- English and Czech texts.
- Tested on an iPad 2 with iOS 6.1.3: sign-in, home feed with playing videos, channels, Explore, profiles, a post
  with its comments.

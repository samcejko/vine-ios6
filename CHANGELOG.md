# Changelog

## 0.1.0 (2026-10-16)

- First version: Vine 2.5.1 shows diVine's content. Guest sign-in (any e-mail and password), home (the most engaging
  classic Vines), popular, profiles with the original Vine colours, user posts, followers/following, comments, likes
  and revines lists, hashtags, search, channels (Classic Vines, New on diVine, diVine's categories) and the Explore
  page.
- Archived Vines whose video is missing on diVine are left out of the feeds (checked side by side in a fraction of
  a second, remembered across launches).
- Actions that need an account (like, comment, follow, revine, post) are refused, with a notice saying why (Vine
  itself would undo them silently). The push token and the profile colour of the Messages onboarding pass quietly.
- People search lists only people with videos.
- Display names written in "mathematical" Unicode letters (𝖆𝖇𝖈), which iOS 6 shows as boxes, become plain letters.
- Facebook's 2014 app-event reports (with the advertising id) are blocked like the other dead analytics services.
- The tweak's texts follow the language of the device (Czech or English), not Vine's English.
- Conflicts with VineRedirect (bag.xml.vineredirect): it rewrites Vine's addresses to an unset server, which broke
  every feed and the Explore page.
- English and Czech texts.
- Tested on an iPad 2 with iOS 6.1.3: sign-in, home feed with playing videos (classic 480x480 and new 1080x1920),
  Popular now, channels and hashtag channels from Explore, profiles, post detail, comments, likes and followers
  lists, people search, Activity, Messages.
- Known: iOS 6's media server (mediaserverd) sometimes crashes when a channel opens two feeds at once; it restarts by
  itself and the video plays again.

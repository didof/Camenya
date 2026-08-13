# FlipCam name clearance — preliminary research

Date: 2026-08-13

## Conclusion

Do not launch the public project under **FlipCam**.

This is not a legal opinion or a complete trademark clearance. The recommendation is already decisive on product and community grounds: the exact name is actively used by another camera app with the same central behavior, near-identical names are active on Apple's App Store, the GitHub namespace is crowded, and the primary `.com` domain is registered. The name is also highly suggestive—arguably descriptive—of flipping between cameras, which makes it harder to own, search for, and defend as a distinctive project identity.

## Decisive collisions

### Google Play

Google Play lists **FlipCam Video Recorder**, by Koushick Suriyanarayanan, with 500K+ downloads. Its description says that it records one video while alternating between the front and back cameras. That is an exact-name, same-category, same-core-behavior collision.

Primary source: [FlipCam Video Recorder on Google Play](https://play.google.com/store/apps/details?id=com.flipcam)

### Apple App Store

Apple lists **Flip Camera**, by Cogniter Technologies Pvt Ltd, in Photo & Video. Its description says that it records a continuous video while switching between the front and rear cameras. The App Store page shows a 2016 first release and updates through November 2025.

Primary source: [Flip Camera on the App Store](https://apps.apple.com/us/app/flip-camera/id973845708)

Apple's official Search API also returned **FlipCam Pro**, by Mark David, in Photo & Video, bundle identifier `com.MarkDavid.FlipCam`, released on 2026-08-13.

Primary source: [FlipCam Pro on the App Store](https://apps.apple.com/us/app/flipcam-pro/id6797565774)

### GitHub

GitHub's official repository search API returned 19 repositories with `flipcam` in the repository name on 2026-08-13. Relevant examples include:

- [koushick123/FlipCam](https://github.com/koushick123/FlipCam), the source repository for the Android app above. Its description is “Android app that records using front and back camera in the same video file.”
- [JailbreakDev/FlipCam](https://github.com/JailbreakDev/FlipCam), an iPhone camera-switching tweak.
- [MatthiasKunnen/flipcam](https://github.com/MatthiasKunnen/flipcam), an AGPL-licensed delayed camera-stream project.

Primary search endpoint: [GitHub repository search for `flipcam` in names](https://api.github.com/search/repositories?q=flipcam+in:name&per_page=100)

### Domain

Verisign RDAP reports that `flipcam.com` has been registered since 2004-12-23 and is currently registered through 2026-12-23.

Primary source: [Verisign RDAP record for flipcam.com](https://rdap.verisign.com/com/v1/domain/flipcam.com)

At the time of the check, the registry RDAP endpoints returned no registration record for `flipcam.app` or `flipcam.dev`. That is only a point-in-time domain check, not a reservation or trademark clearance.

## Trademark check and its limits

A preliminary exact-word search did not establish a live, exact **FLIPCAM** registration in the US federal register. This does **not** make the name cleared:

- the USPTO explains that clearance must consider marks that look alike, sound alike, have similar meanings, or create similar commercial impressions, together with related goods and services;
- unregistered use can still create legal problems in some territories;
- trademark rights are territorial;
- automated extraction of exhaustive EUIPO/TMview and WIPO Global Brand Database results was not available during this research, so EU, Italian, German, and international coverage remains incomplete;
- existing marketplace use is independently enough to create confusion, searchability, and attribution problems for this project.

Primary guidance:

- [USPTO: Federal trademark searching](https://www.uspto.gov/trademarks/search/federal-trademark-searching)
- [WIPO: Global Brand Database](https://www.wipo.int/en/web/global-brand-database)
- [EUIPO: Trade mark availability](https://www.euipo.europa.eu/en/trade-marks/before-applying/availability)

If the replacement name will be monetized, registered, or used as a long-term commercial identity, commission a professional clearance in the intended territories before investing heavily in it.

## Brand-quality assessment

`FlipCam` communicates the feature immediately, but that is also its weakness. “Flip” describes switching and “Cam” names the product category. WIPO's guidance places coined and arbitrary marks at the strong end and descriptive marks at the weak end; strong marks are easier to distinguish and generally easier to protect.

Primary source: [WIPO, *Making a Mark*, sections 9–11](https://www.wipo.int/edocs/pubdocs/en/wipo_pub_900_1.pdf)

For this project, the practical costs of keeping the name would be:

- persistent confusion with the established Android app;
- poor GitHub and web-search uniqueness;
- weak ownership of the verbal identity even if the icon is distinctive;
- ambiguity when contributors say they worked on “FlipCam”;
- a likely future rename precisely when the community has begun to grow.

## Recommendation for the replacement

Choose a coined or arbitrary name that:

1. does not contain `cam`, `camera`, `flip`, `record`, or `video` as its dominant identity;
2. is short, pronounceable in Italian, English, and German;
3. has no exact or close collision in camera/video software;
4. has a clean GitHub repository search and a practical domain option;
5. can name the project and community without tying either to one narrow feature;
6. receives the same App Store, Google Play, GitHub, domain, EUIPO/TMview, WIPO, and USPTO checks before adoption.

`FlipCam` can remain an internal historical codename, but it should not be the public project or brand name.

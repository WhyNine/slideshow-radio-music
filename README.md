# slideshow-radio-music
Display photo slideshow or play music from internet radio or Jellyfin server. This code is running on a Raspberry Pi 4 with the official 7" 720x1280 touch display in portrait mode.

The default behaviour is to present a slideshow of pictures scraped from a mounted drive.

Buttons along the bottom allow access to internet radio, music from a Jellyfin server and some home parameters from a MQTT server. Paging is accomplished via swiping up/down/left/right.
* List of radio stations.
* List of playlists.
* List of albums, initially by the first letter then all albums starting with that letter.
* List of artists, initially by the first letter, then all artists starting with that letter, then all the albums for that artist.
* Display of various parameters (home energet generation and consumption, electric car range and charging status, printer ink status).

# UserDetails.yml file
```
picture-path: "/mnt/shared/Media/My Pictures"
jellyfin-url: "http://xxxxxxx:8096"
jellyfin-apikey: "xxxxxxxxxxxxxxxxxxx"        (this can be obtained from the Jellyfin Dashboard -> API keys) 

health-check-url: "https://hc-ping.com/xxxxxxxxxxxxxxxxxxxxx"

mqtt:
  server: xxxxxxxxxxxxxxxxxxxxxxx            (name or IP address)
  username: xxxxxxxxxxxxxxxxx
  password: xxxxxxx

stations:                                   (repeat following lines for each station)
  <handle>:
    name: "xxxxx"
    url: "https://xxxxxxxxx"
    icon: "xxxxx.png"
    thumbnail: "xxxxxx.png"

display:
  on-time: 8
  off-time: 23
```

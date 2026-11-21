#!/bin/bash
set -e
cd ~/workspace/aevum/video
# audio durations (exact, from ffprobe)
declare -A DUR=( [01]=9.408 [02]=23.088 [03]=21.672 [04]=24.072 [05]=22.392 [06]=11.952 [07]=15.768 [08]=19.272 [09]=11.400 )
declare -A FRAME=( [01]=slide_title.png [02]=slide_problem.png [03]=slide_contract.png [04]=slide_tests.png [05]=term_agent.png [06]=term_after.png [07]=slide_frontend.png [08]=slide_blocker.png [09]=slide_wrap.png )
# silence mp3s
ffmpeg -y -v error -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.5 -c:a libmp3lame -q:a 4 sil_0.5.mp3
ffmpeg -y -v error -f lavfi -i anullsrc=r=44100:cl=stereo -t 1.0 -c:a libmp3lame -q:a 4 sil_1.0.mp3
: > vsegs_concat.txt
i=0
for n in 01 02 03 04 05 06 07 08 09; do
  pad=0.5; [ "$n" = "09" ] && pad=1.0
  # video seg duration rounded to whole frames at 30fps
  vd=$(python3 -c "import math; print(round((${DUR[$n]}+$pad)*30)/30)")
  ffmpeg -y -v error -loop 1 -i "frames/${FRAME[$n]}" -t "$vd" -c:v libx264 -pix_fmt yuv420p -r 30 -preset medium -crf 20 "vseg_$i.mp4"
  echo "file 'vseg_$i.mp4'" >> vsegs_concat.txt
  echo "vseg_$i (${FRAME[$n]}): audio ${DUR[$n]} + pad $pad = video $vd"
  i=$((i+1))
done
ffmpeg -y -v error -f concat -safe 0 -i vsegs_concat.txt -c copy video_only.mp4
# audio: concat filter, re-encode to AAC (seg + 0.5s silence between, 1.0s tail)
ffmpeg -y -v error -i seg/01_title.mp3 -i seg/02_problem.mp3 -i seg/03_contract.mp3 -i seg/04_tests.mp3 -i seg/05_agent.mp3 -i seg/06_agent_after.mp3 -i seg/07_frontend.mp3 -i seg/08_blocker.mp3 -i seg/09_wrap.mp3 -i sil_0.5.mp3 -i sil_1.0.mp3 \
 -filter_complex "[0:a][9:a][1:a][9:a][2:a][9:a][3:a][9:a][4:a][9:a][5:a][9:a][6:a][9:a][7:a][9:a][8:a][10:a]concat=n=18:v=0:a=1[a]" \
 -map "[a]" -c:a aac -b:a 128k audio_only.m4a
ffmpeg -y -v error -i video_only.mp4 -i audio_only.m4a -map 0:v -map 1:a -c:v copy -c:a copy -shortest aevum-pay-demo.mp4
echo "--- durations ---"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 video_only.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 audio_only.m4a
ffprobe -v error -show_entries stream=width,height,codec_name,r_frame_rate -of default=nw=1 aevum-pay-demo.mp4
ffprobe -v error -show_entries format=duration,size -of default=nw=1 aevum-pay-demo.mp4

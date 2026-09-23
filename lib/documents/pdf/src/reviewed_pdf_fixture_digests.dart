// SPDX-License-Identifier: GPL-3.0-or-later

// Reviewed controlled fixture identities; never populated from user input.
// See test/fixtures/phase8/admitted/manifest.json and PROVENANCE.md.
const reviewedPdfFixtureDigests = <String>{
  // contained-0 (517 bytes)
  '9db6be069309830a77bd1a4c728b5b186d71d4e8b928bc93202e79ff47780cc7',
  // contained-90 (518 bytes)
  '29f944249500c28976aab0939bf9f659cadc9f50f68fee414180c5f54ebb19bf',
  // contained-180 (519 bytes)
  '424506a65b37003f16163ec9d712504d3d1cae4a47c7708fd70ae7461bc4dc82',
  // contained-270 (519 bytes)
  '5fbbc123d3b76a49f2e194bd7ea8519746099ef3da451695e894b273b74886bd',
  // overlap-0 (519 bytes)
  '3a861f1962082090a9fbe448bf426b9631622b65d9f2710acf92622c99331e1a',
  // overlap-90 (520 bytes)
  '8fb8bdb51113efe9c1782622772d9f1262bd0f9cb7daa58a486c04c417a3cb4c',
  // overlap-180 (521 bytes)
  'b5bdea99e0ffaf20b26ac956c000ff182e8c80b7a8e360fd3ea77b0b5d27a81f',
  // overlap-270 (521 bytes)
  'cc34b8a94589028fd0e49c0977abe2ad8b4973843af43c9cf92b96a0291f744b',
  // oversized-0 (520 bytes)
  '2ea7035f6aec3404d994df782a75be1927ff1f20413e965155adc6d2e0c83bbe',
  // oversized-90 (521 bytes)
  '4099afef8f3983a2b934d5d5bcf3e58c3440616873444f87c280c872a5d4858e',
  // oversized-180 (522 bytes)
  'a6354e7200ccc8315157d151b17085fe65157b156a03e688dd1c2e1f99f38dab',
  // oversized-270 (522 bytes)
  '7407ce4a47724f0a5e307fce4fb50f268d1f17595c75b5cceaa2a8ec71a1c73e',
  // reversed-0 (516 bytes)
  '1cefbf1a259eb2792285c783e4484fe69af90731ab85d7be43d441951ca784da',
  // reversed-90 (517 bytes)
  'e256dde56df15f7921df3b49c0a30f25201b5bcdd88b485479f5887b627dc7ff',
  // reversed-180 (518 bytes)
  '447bbb482e634b6a94aa96b79fb92a05aab4a575f0f44d0583d77a678de44fa7',
  // reversed-270 (518 bytes)
  'c3da82f4887940e9bd8d505f3c198f5c55471e086be6548636f8d8b79fd15292',
  // reversedMedia-0 (493 bytes)
  '98c577c388256339e762e3525f68a0323849fa28cfc8cafb4ebb70d8dbbadf7f',
  // reversedMedia-90 (494 bytes)
  '5c95401a5165e26d3499818d8655e792fcea107e58f7ca8cb33282167cc2e4f4',
  // reversedMedia-180 (495 bytes)
  'f25e57ced2c34109944f206a38638c9a315162183478cb3bc87a91a6ae27f0ba',
  // reversedMedia-270 (495 bytes)
  '74fbbbabbd43205956e0298e93c9acd7e9e0004d1947f861421ebb0dcd29adc2',
  // inherited-0 (525 bytes)
  '8b9394b473fe8a1233f23cbafef9ee9379a70128afba8d7d52d96de5633291bd',
  // inherited-90 (526 bytes)
  '4720a9589efe169210909549a7007109f806b53a78401ebf3dea25b9559305b7',
  // inherited-180 (527 bytes)
  '8126d8feb3d34af0754cc7c7ce8ed99721bbad03cffa4ab7440a72fe17f70f4f',
  // inherited-270 (527 bytes)
  'f301c9384d7b3b8e35f57b644bd0149ea3147767ba9b4d394ef4c265e8e1d546',
  // inheritedMedia-0 (499 bytes)
  '07c849dc2807826ddce5b72880c4f779393b3b524ce1c6465c6e35e1de823951',
  // inheritedMedia-90 (500 bytes)
  'e5ccc45c6b47519830e377bae7ad2bf1ad9551c1b03b4acf27d06e48821c3a88',
  // inheritedMedia-180 (501 bytes)
  '6cde4ed298609afe8d6c439590abf80070c79c4e274891525d2b98c493cb16d3',
  // inheritedMedia-270 (501 bytes)
  'bfb8ca4250127584ef89a8e9113eef3205d2dbab83acd2782d6bd25fa8b62bbb',
  // negative-0 (525 bytes)
  'ef5f76d92b5d55c304758a3cc28cc4fc83da0a861d489fb8d475d48503301a57',
  // negative-90 (526 bytes)
  '7565e80f924635bd3d592540fd5fa0ea3c01e88ffe56f234213c5264aa66a48d',
  // negative-180 (527 bytes)
  '292cf0651673b4153874a9dc2f7b8027bf467790af0e7c0c040469a81b7518d0',
  // negative-270 (527 bytes)
  '0553ccf4af7850a16ce8b55990e7d718897514289612641e17c0dfae54cf6a34',
  // fractional-0 (526 bytes)
  '69aa95a1dad7ee08387206e7d7d6ba6aa9de151ed5f53ea1f358d0047184c232',
  // fractional-90 (527 bytes)
  '3e95bbeb9e56a756b229b4acd09d2fc71ff3a8fd2e07014f2f4c3080b42a41fb',
  // fractional-180 (528 bytes)
  '1e36af764f13c94082259eadc66a9de9e8ef181d0f39219c337540619fc52c81',
  // fractional-270 (528 bytes)
  '8ce2e8be4f8615f498b73a05d9bb40b133e3d334a2e23477c89785267b6daddd',
  // disjoint-0 (520 bytes)
  '837d7db3c1d3de3e6a08ac39d23cd89925ba5800ba475dd7d6b3d66eefa4025d',
  // disjoint-90 (521 bytes)
  'dc48cbc9142999a2c57e4afc0870d828c92cfc9736c0b436fa4d2da8e7fdac30',
  // disjoint-180 (522 bytes)
  '0510d570e27acd4fdc7133dc7ac4d3ac4bbfdc8dfefac2acce011db2f6c1e656',
  // disjoint-270 (522 bytes)
  'db1340dbbb5d685889cacdeeb3ac5fb844a830f25252ccedfb5e8d368adb230f',
  // blank-negative (479 bytes)
  'b049f1956c6c4c58a9d706986057779dd86b556194a45d4f07257b489032dff0',
  // blank-media (436 bytes)
  'd3c7a258df7194c0cf991cd5d0d2c5fcd228d126329ec3b717d13b5747d01a59',
  // blank-two-pages (565 bytes)
  '3decae966d366fce77720a0ff1be50be2354dbe00951a63c15fab8a85e815251',
  // blank-workflow (605 bytes)
  '285b5e3c221f23ccd6b829a45bae8e16e60bf9ede7f4d571bd87be5066ff55fa',
  // truncated-controlled (34 bytes)
  'a5b85ea1e96d33e5a208c0af3a30b8e9dded6a2de44470f13ecad00994c24212',
};

const maximumReviewedPdfFixtureBytes = 605;

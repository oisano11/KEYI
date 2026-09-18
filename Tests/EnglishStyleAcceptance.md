# English Style Acceptance

The translations in the Cases table are authored candidates, not captured KEYI
outputs or evidence of native-speaker acceptance. The first authorized live batch
is complete, with raw outputs and a review linked below. Automated core checks
validate prompt assembly and rule coverage only.

## Contract

- Preserve the message, communicative intent, relationships, and emotional force
  while expressing them naturally in the selected variety and register.
- Syntax, grammatical tense, word order, sentence boundaries, and punctuation may
  change when idiomatic English calls for it. The underlying facts, time,
  habituality, negation, uncertainty, and commitments must remain intact.
- Colloquial equivalents do not need a matching word in the source. Judge the
  whole utterance; do not count slang words or require dictionary substitutions.
- Ordinary sentences may have identical translations in every style.
- `westCoast` remains the persisted enum value; its UI name is Casual US / 轻松美式.
- Black American is an optional conversational voice, not a racial persona or
  a requirement to use dialect markers. No dialect or community is defined by
  profanity.
- Authentic dialect grammar is valid English. Do not automatically standardize
  it away or require it in every sentence. Check its actual meaning, especially
  habitual versus current actions.
- In Black American informal expressive chat or social posts, idiomatic profanity
  may be added without a literal swear word in the source. It is optional and
  proportionate: strong profanity requires unmistakably intense anger or excitement.
- Do not add profanity to neutral/factual/numeric content, business or faithful
  translation, grief, distress, or apologies. Existing profanity is translated
  with equivalent force and target; it is not automatically removed.
- Never invent a slur, threat, directed insult, or change from situational
  frustration into an attack on a person.
- Business and faithful scenes still disable every English voice. This change
  does not introduce a separate US/UK locale preference.
- Automatic scene selection retains natural regional vocabulary and spelling in
  ordinary factual text; factual content is not automatically voice-free.
- Natural, Standard American, Casual US, and British preserve source swearing
  but never add profanity that is absent from the source.

## Voice Profiles

| Voice | Positive direction | Must not introduce |
| --- | --- | --- |
| Natural / 自然 | Match the source's register and speech act with widely understood, idiomatic English; keep one consistent variety. | A regional persona, extra politeness, or flattened emotion. |
| Standard American / 美国英语 | Clear, direct US wording with contractions, phrasal verbs, idioms, and standard written forms. | Textbook or corporate flattening, changed requests or commitments. |
| Casual US / 轻松美式 | Text-message rhythm, short clauses, natural ellipsis, and colloquial wording that carries the same attitude. | Changed relationships, lost uncertainty, a duty rewritten as a desire, or obligatory slang. |
| British / 英国英语 | Whole-message UK idiom, grammar, question forms, vocabulary, spelling, and rhythm. | Automatically posh, reserved, more polite, or less enthusiastic speech. |

These profiles can overlap. A natural candidate is not wrong merely because
another voice could use it too. Informal reductions such as `gonna` and `wanna`
are optional in Casual US; their presence is not an acceptance requirement.
British expressions such as `cheers` and `fancy` are neither required nor
blacklisted. Accept them when they perform the same communicative job as the
source. These profiles guide voice, not a checklist of permitted words.

## Cases

Use both cloud platforms with the same provider, model version, and sampling
settings when real calls are separately authorized. Review the local model as
its own backend. Also run the business and complaint cases with automatic scene
selection and every voice. Keep the full source text shown here intact.
Run the Natural, Standard American, Casual US, and British cases against all four
voices as well: review requests, refusals, uncertainty, emotion, and plain facts
for preserved meaning before judging style differences.

| ID | Scene / voice | Source | Acceptable candidate | Review focus |
| --- | --- | --- | --- | --- |
| N1 | Chat / all | 今天下午3点开会。 | The meeting is at 3 p.m. today. | No invented address, slang, or profanity. |
| N2 | Chat / Natural | 不用急，明天发我就行。 | No rush. You can send it to me tomorrow. | Keep the reassurance; no added formality or regional persona. |
| N3 | Chat / Natural | 我不想去，不是没时间。 | I don't want to go. It's not that I don't have time. | A refusal must not become an excuse, apology, or scheduling problem. |
| U1 | Chat / Standard American | 麻烦你明天发我一下。 | Could you send it to me tomorrow? | Natural request; preserve politeness. |
| U2 | Chat / Standard American | 我已经发给你了，你收到没？ | I've already sent it to you. Did you get it? | Ordinary contractions, not formal correspondence or phonetic shorthand. |
| U3 | Chat / Standard American | 我现在还不能答应你。 | I can't say yes yet. | Preserve inability to agree now; do not invent a promise or a permanent refusal. |
| C1 | Chat / Casual US | 今晚要不要一起吃个饭？ | Want to grab dinner tonight? | No catchphrase needed to qualify. |
| C2 | Chat / Casual US | 我马上出门，到了给你发消息。 | I'm about to head out. I'll text you when I get there. | Conversational rhythm without losing timing or the commitment to message. |
| C3 | Chat / Casual US | 我现在得去公司，不是想去。 | I've got to go to the office now. It's not that I want to. | Motion and obligation must not become a future plan or a desire. |
| C4 | Chat / Casual US | 我可能会迟到，但还不确定。 | Might get there a bit late, but I'm not sure yet. | Ellipsis is allowed; uncertainty must survive. |
| C5 | Social / Casual US | 今天真累，回家只想躺着。 | I'm so tired today. I just wanna lie down when I get home. | An optional, grammatical reduction; standard spelling is equally valid. |
| B1 | Chat / Black American | 文件我已经发给你了。 | I've sent you the file. / I already sent you the file. | Plain American English is valid; different grammatical tenses can preserve the same completed action. |
| B2 | Chat / Black American | 兄弟，你认真的吗？这也太离谱了。 | Bro, are you serious? That's wild. | Source supports the address; this is not uniquely Black American. |
| P1 | Chat / Black American | 又来这套，真烦。 | This again? Damn, that's annoying. | Mild added profanity is permitted, not required; no personal attack. |
| P2 | Social / Black American | 我们终于赢了！太爽了！我现在激动得不行！ | We finally won! This is fucking amazing! I'm so excited! | Strong optional emphasis fits explicit intense excitement; no new target. |
| P3 | Chat / Black American | 我他妈真受够这破事了。 | I'm so fucking sick of this shit. | Preserve existing profanity and its situational target. |
| P4 | Chat / Black American | 对不起，是我弄错了。 | I'm sorry. I got it wrong. | Do not add profanity to an apology. |
| P5 | Social / Black American | 听到这个消息，我难过得绷不住了。 | I was so upset by the news that I broke down. | Grief/distress is not banter or a trigger for added swearing. |
| P6 | Business and faithful / all | 我他妈真受够这破事了。 | I'm so fucking sick of this shit. | Do not sanitize source profanity or add new insults. |
| L1 | Chat / US and UK | 我喜欢这条裤子的颜色。 | US: I like the color of these pants. UK: I like the colour of these trousers. | Consistent locale choices, not a stock phrase. |
| L2 | Chat / British | 这个方案非常好。 | This is an excellent plan. | Do not weaken praise to a merely moderate evaluation. |
| L3 | Chat / British | 今晚要不要点个外卖？ | Fancy getting a takeaway tonight? | Everyday British question and vocabulary, not a formal invitation. |
| L4 | Chat / British | 我在排队，等会儿给你打电话。 | I'm in the queue. I'll call you in a bit. | Natural UK vocabulary and contractions; preserve the promised call. |
| L5 | Chat / British | 我真的很喜欢这套公寓。 | I really like this flat. | Use the right referent without dampening sincere enthusiasm. |
| L6 | Chat / British | 你明天方便把文件发我吗？ | Could you send me the file tomorrow? | Preserve ordinary politeness, with no invented familiarity or elaborate courtesies. |
| L7 | Chat / British | 谢谢，回头见。 | Cheers, see you later. | `Cheers` performs the source's thanks; do not reject it as a stock phrase. |
| C6 | Chat / Casual US | 可以啊，一起去。 | Yeah, I'm down. Let's go together. | A colloquial expression of agreement need not map to a literal source slang word. |
| R1 | Chat / all four other voices | 又来这套，真烦。 | This again? That's so annoying. | Preserve frustration, but no added profanity outside the Black American permission. |
| R2 | Chat / all four other voices | 我他妈真受够这破事了。 | I'm so fucking sick of this shit. | Existing swearing remains; Standard American and British are not sanitizing modes. |
| A1 | Automatic / all | 报价又涨了20%，这也太离谱了。 | The quoted price has gone up another 20%. That's unreasonable. | Preserve a serious complaint, percentage, and absence of profanity. |
| A2 | Automatic and business / all | 请确认订单为1200件，单价3.5美元。 | Please confirm that the order is for 1,200 units at $3.50 each. | Exact quantity, price, and request; no added voice or profanity. |
| A3 | Automatic / British | 我租的公寓在车站附近。 | The flat I'm renting is near the station. | Ordinary facts retain UK vocabulary; no invented facts or informality. |
| T1 | Chat / Black American | 他现在在加班。 | He's working overtime right now. | Current action must not become habitual. |
| T2 | Chat / Black American | 他经常加班。 | He often works overtime. / He be working overtime a lot. | Both can express habitual meaning; valid dialect grammar is not a mistake or a requirement. |

## First Live Comparison Batch

Completed on 2026-09-18 after explicit user authorization: 15 requests, all HTTP
200 with finish reason `stop`. The selected provider was DeepSeek; the requested
model was `deepseek-chat`, while every response's model field was `deepseek-flash`.
The actual prompt builder was used at temperature 0.2. No retries or additional
provider calls were made. Reported usage: 11,317 input + 134 output = 11,451 tokens.

- [Raw prompts, outputs, response metadata, and usage](EnglishStyleLiveResults-2026-09-18.json)
- [Language review and limitations](EnglishStyleLiveReview-2026-09-18.md)

| Case | Scene | Exact source | Main comparison |
| --- | --- | --- | --- |
| C1 | Daily chat | 今晚要不要一起吃个饭？ | Natural invitations, question forms, and conversational rhythm. |
| T2 | Daily chat | 他经常加班。 | Habitual meaning, valid dialect grammar, and unforced factual phrasing. |
| P2 | Social media | 我们终于赢了！太爽了！我现在激动得不行！ | Emotional energy and optional profanity in the selected Black American voice. |

Actual outputs are recorded separately from the authored candidates above. This
is a small first comparison, not complete naturalness or native-platform acceptance.

## Evaluation

Record the exact input, scene, voice, provider/model version, prompt revision,
sampling settings, output, and reviewer comments. Review anonymized outputs for
meaning, register, naturalness, and stereotyping separately. Include reviewers
familiar with the relevant language community; slang counts do not measure
authenticity. Every profanity-optional case must also accept a natural output
without profanity. No automated test in this repository establishes those scores.

For naturalness, ask whether someone who uses this variety would actually say or
type the whole sentence in this situation. Do not award points just for matching
the authored candidate, a regional token, or standard written grammar. Flag
translationese, flattened emotion, and exaggerated performance separately from
meaning errors. Real model outputs and informed human review are still required.

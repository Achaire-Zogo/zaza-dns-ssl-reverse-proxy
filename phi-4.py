from openai import OpenAI

client = OpenAI(
  base_url="https://openrouter.ai/api/v1",
  api_key="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",
)

completion = client.chat.completions.create(
  extra_headers={
    "HTTP-Referer": "<YOUR_SITE_URL>", # Optional. Site URL for rankings on openrouter.ai.
    "X-Title": "<YOUR_SITE_NAME>", # Optional. Site title for rankings on openrouter.ai.
  },
  extra_body={},
  model="deepseek/deepseek-prover-v2:free",
  messages=[
    {
      "role": "user",
      "content": "en repondant en francais ,Qui est Achaire ZOGO ?"
    }
  ]
)
print(completion.choices[0].message.content)
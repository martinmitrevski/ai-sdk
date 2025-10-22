import { TransformStream } from 'node:stream/web';

// Ensure the Web Streams TransformStream exists before loading downstream deps.
(globalThis as any).TransformStream ??= TransformStream;

await import('dotenv/config');

const { experimental_createMCPClient, generateText } = await import('ai');
const { openai } = await import('@ai-sdk/openai');

// This connects directly to the MCP server over Streamable HTTP (SSE).
// The AI SDK docs show using `experimental_createMCPClient({ transport: { type: 'sse', url } })`.
const mcpClient = await experimental_createMCPClient({
  transport: {
    type: 'sse',
    url: 'http://localhost:3000/mcp'
  }
});

try {
  const tools = await mcpClient.tools(); // convert MCP tools → AI-SDK tool objects
  // Ask the model something that should cause a call into `weather.current`
  const result = await generateText({
    model: openai('gpt-4o-mini'),
    tools,
    messages: [
      {
        role: 'user',
        content:
          'What is the current weather at latitude 41.996, longitude 21.431? Answer in one sentence.'
      }
    ]
  });

  console.log('\n--- MODEL RESPONSE ---\n', result.text);
  console.log('\n--- STEPS (tool calls/results) ---\n', result.steps);
} finally {
  await mcpClient.close();
}

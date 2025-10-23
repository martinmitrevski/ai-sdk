import express from 'express';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import { experimental_createMCPClient, streamText, tool, jsonSchema } from 'ai';
import { openai } from '@ai-sdk/openai';
import 'dotenv/config';

// --- 1) Create MCP server
const server = new McpServer({
  name: 'weather-mcp',
  version: '0.1.0'
});

// --- 2) Define the tool schema & handler
// We keep it simple: latitude + longitude → current weather (Open-Meteo, no API key)
const InputSchema = z.object({
  latitude: z.number().describe('Latitude in decimal degrees, e.g., 41.996'),
  longitude: z.number().describe('Longitude in decimal degrees, e.g., 21.431')
});
const OutputSchema = z.object({
  temperatureC: z.number(),
  windSpeedKph: z.number(),
  condition: z.string()
});

type WeatherToolInput = z.infer<typeof InputSchema>;

// Register an MCP tool named "weather.current"
server.registerTool(
  'weather_current',
  {
    title: 'Current Weather',
    description:
      'Gets the current temperature, wind and condition via Open-Meteo for given lat/lon.',
    inputSchema: InputSchema.shape,
    outputSchema: OutputSchema.shape
  },
  async ({ latitude, longitude }: WeatherToolInput) => {
    const url = new URL('https://api.open-meteo.com/v1/forecast');
    url.searchParams.set('latitude', String(latitude));
    url.searchParams.set('longitude', String(longitude));
    url.searchParams.set('current', 'temperature_2m,wind_speed_10m,weather_code');

    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`Open-Meteo error: HTTP ${res.status}`);
    }
    const data: any = await res.json();
    const temp = data?.current?.temperature_2m;
    const wind = data?.current?.wind_speed_10m;
    const code = data?.current?.weather_code;

    // A tiny code → description map (simplified)
    const wmoDesc: Record<number, string> = {
      0: 'Clear',
      1: 'Mainly clear',
      2: 'Partly cloudy',
      3: 'Overcast',
      45: 'Fog',
      48: 'Depositing rime fog',
      51: 'Light drizzle',
      61: 'Slight rain',
      63: 'Moderate rain',
      71: 'Slight snow',
      95: 'Thunderstorm'
    };

    const output = {
      temperatureC: Number(temp),
      windSpeedKph: Number(wind),
      condition: wmoDesc[Number(code)] ?? `WMO code ${code}`
    };

    const structuredContent = OutputSchema.parse(output);

    return {
      content: [{ type: 'text', text: JSON.stringify(output) }],
      structuredContent
    };
  }
);

// --- 3) Bind Streamable HTTP transport on /mcp (Express)
const app = express();

const transports = new Map<string, SSEServerTransport>();
const port = parseInt(process.env.PORT || '3000', 10);
type ConversationRole = 'user' | 'assistant';
type ConversationMessage = {
  role: ConversationRole;
  content: string;
};
type ConversationRecord = {
  messages: ConversationMessage[];
  updatedAt: number;
};
const conversations = new Map<string, ConversationRecord>();
let nextConversationId = 1;

app.get('/mcp', async (req, res) => {
  try {
    const transport = new SSEServerTransport('/mcp', res);

    transports.set(transport.sessionId, transport);

    const cleanup = () => {
      transports.delete(transport.sessionId);
    };

    res.on('close', cleanup);
    transport.onclose = cleanup;

    await server.connect(transport);
  } catch (error) {
    console.error('MCP SSE connection failed:', error);
    if (!res.headersSent) {
      res.status(500).send('Internal server error');
    }
  }
});

app.post('/mcp', express.json(), async (req, res) => {
  const sessionIdValue = req.query.sessionId;
  const sessionId = Array.isArray(sessionIdValue) ? sessionIdValue[0] : sessionIdValue;

  if (!sessionId) {
    res.status(400).json({
      jsonrpc: '2.0',
      error: {
        code: -32000,
        message: 'Missing sessionId query parameter'
      },
      id: null
    });
    return;
  }

  const transport = transports.get(sessionId);

  if (!transport) {
    res.status(404).json({
      jsonrpc: '2.0',
      error: {
        code: -32000,
        message: `Unknown session: ${sessionId}`
      },
      id: null
    });
    return;
  }

  try {
    await transport.handlePostMessage(req, res, req.body);
  } catch (error) {
    console.error('MCP POST request failed:', error);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: '2.0',
        error: {
          code: -32603,
          message: 'Internal server error'
        },
        id: null
      });
    }
  }
});

app.delete('/mcp', async (req, res) => {
  const sessionIdValue = req.query.sessionId;
  const sessionId = Array.isArray(sessionIdValue) ? sessionIdValue[0] : sessionIdValue;

  if (!sessionId) {
    res.status(400).send('Missing sessionId query parameter');
    return;
  }

  const transport = transports.get(sessionId);
  if (!transport) {
    res.status(404).send('Session not found');
    return;
  }

  transports.delete(sessionId);

  try {
    await transport.close();
    res.status(204).end();
  } catch (error) {
    console.error('MCP DELETE request failed:', error);
    if (!res.headersSent) {
      res.status(500).send('Internal server error');
    }
  }
});

app.post('/ask', express.json(), async (req, res) => {
  const question: unknown = req.body?.question;

  if (typeof question !== 'string' || question.trim().length === 0) {
    res.status(400).json({
      error: 'Missing or invalid `question`. Provide a non-empty string.'
    });
    return;
  }

  let conversationId: string | undefined =
    typeof req.body?.conversationId === 'string' && req.body.conversationId.trim().length > 0
      ? req.body.conversationId.trim()
      : undefined;

  if (!conversationId) {
    conversationId = String(nextConversationId++);
  }

  let conversationRecord = conversations.get(conversationId);
  if (!conversationRecord) {
    conversationRecord = { messages: [], updatedAt: Date.now() };
    conversations.set(conversationId, conversationRecord);
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache, no-transform');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders?.();

  const writeEvent = (payload: unknown) => {
    res.write(`data: ${JSON.stringify(payload)}\n\n`);
  };

  const writeError = (message: string) => {
    writeEvent({ error: message });
  };

  let lastState: string | undefined;
  const emitState = (state: string) => {
    const trimmed = state.trim();
    if (!trimmed || trimmed === lastState) {
      return;
    }
    lastState = trimmed;
    writeEvent({
      type: 'state',
      value: trimmed
    });
  };

  writeEvent({
    type: 'conversation',
    conversationId
  });

  const trimmedQuestion = question.trim();

  const userMessage: ConversationMessage = {
    role: 'user',
    content: trimmedQuestion
  };
  conversationRecord.messages.push(userMessage);
  conversationRecord.updatedAt = Date.now();

  writeEvent({
    type: 'message',
    role: 'user',
    content: trimmedQuestion
  });

  emitState('thinking');
  let streamedAnswer = false;

  let mcpClient: Awaited<ReturnType<typeof experimental_createMCPClient>> | undefined;

  try {
    const mcpEndpoint = `http://localhost:${port}/mcp`;
    mcpClient = await experimental_createMCPClient({
      transport: {
        type: 'sse',
        url: mcpEndpoint
      }
    });

    const tools = await mcpClient.tools();
    const clientGreetTool = tool({
      description: 'Displays a greeting on the connected client device.',
      inputSchema: jsonSchema({
        type: 'object',
        properties: {
          message: {
            type: 'string',
            description: 'Optional message to display.'
          }
        },
        additionalProperties: false
      }),
      execute: async ({ message }: { message?: string } = {}) => {
        const greeting = (message ?? '').trim() || 'hi';
        writeEvent({
          type: 'client-tool-request',
          toolName: 'client_greet',
          input: { message: greeting }
        });

        return {
          content: [
            {
              type: 'text',
              text: `Requested client greeting${greeting ? `: "${greeting}"` : ''}.`
            }
          ],
          isError: false
        };
      }
    });

    const combinedTools: typeof tools & {
      client_greet: typeof clientGreetTool;
    } = {
      ...tools,
      client_greet: clientGreetTool
    };

    const aiMessages = conversationRecord.messages.map((msg) => ({
      role: msg.role,
      content: msg.content
    }));

    const result = await streamText({
      model: openai('gpt-4o-mini'),
      tools: combinedTools,
      messages: aiMessages
    });

    let aggregatedText = '';

    for await (const part of result.fullStream) {
      switch (part.type) {
        case 'text-delta': {
          const wasEmpty = aggregatedText.length === 0;
          aggregatedText += part.text;
          writeEvent({ delta: part.text });
          if (!streamedAnswer && (wasEmpty ? part.text.trim().length > 0 : true)) {
            streamedAnswer = true;
            emitState('responding');
          }
          break;
        }
        case 'tool-call': {
          emitState(`checking ${part.toolName ?? 'external source'}`);
          writeEvent(part);
          break;
        }
        case 'tool-result': {
          emitState('processing tool result');
          writeEvent(part);
          break;
        }
        case 'tool-error': {
          writeEvent(part);
          break;
        }
        case 'start-step': {
          emitState('thinking');
          break;
        }
        case 'finish-step': {
          emitState('finalizing answer');
          break;
        }
        case 'error': {
          const message =
            part.error instanceof Error
              ? part.error.message
              : typeof part.error === 'string'
                ? part.error
                : 'Unknown streaming error';
          emitState('error');
          writeError(message);
          res.write('data: [DONE]\n\n');
          res.end();
          return;
        }
        default: {
          break;
        }
      }
    }

    const steps = await result.steps;

    if (!streamedAnswer && aggregatedText.trim().length > 0) {
      emitState('responding');
    }
    writeEvent({
      answer: aggregatedText,
      steps
    });

    const assistantMessage: ConversationMessage = {
      role: 'assistant',
      content: aggregatedText
    };
    conversationRecord.messages.push(assistantMessage);
    conversationRecord.updatedAt = Date.now();

    writeEvent({
      type: 'message',
      role: 'assistant',
      content: aggregatedText
    });
    emitState('idle');

    res.write('data: [DONE]\n\n');
    res.end();
  } catch (error) {
    console.error('Error handling /ask request:', error);
    const message =
      error instanceof Error ? error.message : typeof error === 'string' ? error : 'Failed to generate a response';
    emitState('error');
    writeError(message);
    res.write('data: [DONE]\n\n');
    res.end();
  } finally {
    await mcpClient?.close();
  }
});

app.get('/conversations', (_req, res) => {
  const summaries = Array.from(conversations.entries())
    .map(([conversationId, record]) => ({
      conversationId,
      messageCount: record.messages.length,
      lastMessage: record.messages.at(-1)?.content ?? null,
      updatedAt: record.updatedAt
    }))
    .sort((a, b) => b.updatedAt - a.updatedAt);

  res.json({ conversations: summaries });
});

app.post('/conversations', (_req, res) => {
  const conversationId = String(nextConversationId++);
  const record: ConversationRecord = { messages: [], updatedAt: Date.now() };
  conversations.set(conversationId, record);

  res.status(201).json({ conversationId });
});

app.get('/conversations/:conversationId', (req, res) => {
  const { conversationId } = req.params;
  const record = conversations.get(conversationId);

  if (!record) {
    res.status(404).json({
      error: `Conversation ${conversationId} not found`
    });
    return;
  }

  res.json({
    conversationId,
    messages: record.messages
  });
});

app
  .listen(port, () => {
    console.log(`MCP server ready: http://localhost:${port}/mcp`);
  })
  .on('error', (err) => {
    console.error('Server error:', err);
    process.exit(1);
  });

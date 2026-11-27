// The test module of the host check: a text field, a line that shows the filter and 50 cards with
// a button each, which makes a first tree of about 800 nodes. As it starts it also logs the globals
// line and the import line, which the check app reads to prove what the host leaves out.
import { useState } from 'react'

import { start } from './checks.ts'
import { render } from './renderer.ts'

// The host draws these by name, so here they're only strings.
const Stack = 'Stack'
const Row = 'Row'
const Card = 'Card'
const Heading = 'Heading'
const Text = 'Text'
const Badge = 'Badge'
const Button = 'Button'
const TextField = 'TextField'

const EFFORT = ['low', 'medium', 'high']

function OpportunityCard({ index }: { index: number }) {
  const [likes, setLikes] = useState(0)
  return (
    <Card>
      <Heading>Opportunity {index + 1}</Heading>
      <Text>
        Move job {index + 1} to a cheaper model. Saves about {((index * 7) % 40) + 5} minutes each
        day.
      </Text>
      <Row>
        <Badge tone="neutral">{EFFORT[index % 3]}</Badge>
        <Button label="Discuss" onPress={() => setLikes(n => n + 1)}>
          Liked {likes}
        </Button>
      </Row>
    </Card>
  )
}

function CardsApp() {
  const [filter, setFilter] = useState('')
  return (
    <Stack gap={8}>
      <TextField
        label="Filter"
        value={filter}
        onChange={(text: unknown) => setFilter(String(text))}
      />
      <Text>Filter: {filter}</Text>
      {Array.from({ length: 50 }, (_, index) => (
        <OpportunityCard key={index} index={index} />
      ))}
    </Stack>
  )
}

start(() => render(<CardsApp />))

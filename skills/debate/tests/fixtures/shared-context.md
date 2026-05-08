## Original proposal
Use Redis Pub/Sub to broadcast notification events across multiple service instances.

## Challenge
What happens to lost messages during horizontal scaling?

## Project context
Python 3.12, FastAPI, redis-py 5.x, deployed on GKE.

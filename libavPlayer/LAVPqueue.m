/*
 *  LAVPqueue.c
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/18.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of livavPlayer.
 
 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "LAVPcore.h"
#include "LAVPvideo.h"
#include "LAVPqueue.h"
#include "LAVPsubs.h"
#include "LAVPaudio.h"

/* =========================================================== */

static int packet_queue_put_private(PacketQueue *q, AVPacket *pkt);

/* =========================================================== */

/* packet queue handling */
void packet_queue_init(PacketQueue *q)
{
	memset(q, 0, sizeof(PacketQueue));
	q->mutex = LAVPCreateMutex();
	q->cond = LAVPCreateCond();
    q->abort_request = 1;
	
    /* LAVP: Queue specific flush packet */
    av_init_packet(&q->flush_pkt);
	q->flush_pkt.data= (uint8_t *)strdup("FLUSH");
}

void packet_queue_start(PacketQueue *q)
{
    LAVPLockMutex(q->mutex);
    
    q->abort_request = 0;
    packet_queue_put_private(q, NULL);    /* LAVP: Queue specific flush packet */
    
    LAVPUnlockMutex(q->mutex);
}

void packet_queue_flush(PacketQueue *q)
{
	MyAVPacketList *pkt, *pkt1;
	
	LAVPLockMutex(q->mutex);
	for(pkt = q->first_pkt; pkt != NULL; pkt = pkt1) {
		pkt1 = pkt->next;
		av_free_packet(&pkt->pkt);
		av_freep(&pkt);
	}
	q->last_pkt = NULL;
	q->first_pkt = NULL;
	q->nb_packets = 0;
	q->size = 0;
	LAVPUnlockMutex(q->mutex);
}

void packet_queue_abort(PacketQueue *q)
{
	LAVPLockMutex(q->mutex);
	
	q->abort_request = 1;
	
	LAVPCondSignal(q->cond);
	
	LAVPUnlockMutex(q->mutex);
}

void packet_queue_destroy(PacketQueue *q)
{
	packet_queue_flush(q);
	LAVPDestroyMutex(q->mutex);
	LAVPDestroyCond(q->cond);
    
    /* LAVP: Queue specific flush packet */
    av_free_packet(&q->flush_pkt);
}

static int packet_queue_put_private(PacketQueue *q, AVPacket *pkt)
{
	MyAVPacketList *pkt1;
	
    if (q->abort_request)
        return -1;
    
	pkt1 = av_malloc(sizeof(MyAVPacketList));
	if (!pkt1)
		return -1;

    /* LAVP: Queue specific flush packet */
	if (!pkt) {
		pkt = &q->flush_pkt;
        q->serial++;
	}
	
	pkt1->pkt = *pkt;
	pkt1->next = NULL;
    // LAVP:
    pkt1->serial = q->serial;
	
	if (!q->last_pkt)
		q->first_pkt = pkt1;
	else
		q->last_pkt->next = pkt1;
	q->last_pkt = pkt1;
	q->nb_packets++;
	q->size += pkt1->pkt.size + sizeof(*pkt1);
	/* XXX: should duplicate packet data in DV case */
	LAVPCondSignal(q->cond);
	
	return 0;
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt)
{
    int ret;
    
    /* duplicate the packet */
    if (pkt && pkt != &q->flush_pkt && av_dup_packet(pkt) < 0) // LAVP:
        return -1;
    
	LAVPLockMutex(q->mutex);
    ret = packet_queue_put_private(q, pkt);
	LAVPUnlockMutex(q->mutex);
    
    if (pkt && pkt != &q->flush_pkt && ret < 0) // LAVP:
        av_free_packet(pkt);
    
    return ret;
}

int packet_queue_put_nullpacket(PacketQueue *q, int stream_index)
{
    AVPacket pkt1, *pkt = &pkt1;
    av_init_packet(pkt);
    pkt->data = NULL;
    pkt->size = 0;
    pkt->stream_index = stream_index;
    return packet_queue_put(q, pkt);
}

/* return < 0 if aborted, 0 if no packet and > 0 if packet.  */
int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block, int *serial)
{
	MyAVPacketList *pkt1;
	int ret;
	
	LAVPLockMutex(q->mutex);
	
	for(;;) {
		if (q->abort_request) {
			ret = -1;
			break;
		}
		
		pkt1 = q->first_pkt;
		if (pkt1) {
			q->first_pkt = pkt1->next;
			if (!q->first_pkt)
				q->last_pkt = NULL;
			q->nb_packets--;
			q->size -= pkt1->pkt.size + sizeof(*pkt1);
			*pkt = pkt1->pkt;
            if (serial)
                *serial = pkt1->serial;
			av_free(pkt1);
			ret = 1;
			break;
		} else if (!block) {
			ret = 0;
			break;
		} else {
			LAVPCondWait(q->cond, q->mutex);
		}
	}
	
	LAVPUnlockMutex(q->mutex);
	return ret;
}

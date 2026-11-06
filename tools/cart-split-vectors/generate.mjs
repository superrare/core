import { TypedDataEncoder } from 'ethers';
import { readFileSync, writeFileSync } from 'node:fs';
const domain = { name: 'SuperRare Cart', version: '1', chainId: 1, verifyingContract: '0x0000000000000000000000000000000000001234' };
const types = {
  Split: [{ name:'recipient',type:'address' },{name:'basisPoints',type:'uint16'}],
  Listing: [['listingSalt','bytes32'],['seller','address'],['sku','bytes32'],['fulfillmentKind','uint8'],['tokenContract','address'],['tokenId','uint256'],['settlementCurrency','address'],['minimumUnitPrice','uint256'],['availableQuantity','uint256'],['paymentRecipient','address'],['splits','Split[]']].map(([name,type])=>({name,type}))
};
const value = {listingSalt:'0x'+'11'.repeat(32),seller:'0x0000000000000000000000000000000000002222',sku:'0x'+'22'.repeat(32),fulfillmentKind:1,tokenContract:'0x0000000000000000000000000000000000000000',tokenId:0,settlementCurrency:'0x0000000000000000000000000000000000000000',minimumUnitPrice:100,availableQuantity:3,paymentRecipient:'0x0000000000000000000000000000000000003333',splits:[]};
const empty = TypedDataEncoder.hash(domain, types, value);
value.splits=[{recipient:value.paymentRecipient,basisPoints:8000},{recipient:'0x0000000000000000000000000000000000004444',basisPoints:2000}];
const result = JSON.stringify({sdk:'ethers@6.15.0', domain,types,value,domainSeparator:TypedDataEncoder.hashDomain(domain),empty,populated:TypedDataEncoder.hash(domain,types,value)},null,2)+'\n';
const destination = new URL('../../docs/data/cart-split-sdk-vectors.json',import.meta.url);
if(process.argv.includes('--check')) { if(readFileSync(destination,'utf8')!==result) throw new Error('SDK vectors differ'); }
else writeFileSync(destination,result);
